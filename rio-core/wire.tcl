# rio-core — JSON wire encoding for the socket transport (AGENTS.md D11).
#
# The canonical internal form is plain Tcl dicts (D11: the in-process path uses
# them with no serialization). JSON exists only at the socket boundary, and a
# *generic* dict->JSON encoder is impossible — Tcl can't distinguish the string
# "hi there" from the two-element list {hi there}. So encoding is SHAPE-AWARE:
#
#   - The envelope shape is fixed: id (wire string), ok (bare true/false),
#     and either result (object) or error (a flat {code, message} object, O2).
#   - result and event params are flat objects whose leaf values are emitted as
#     JSON strings. That is exact for every current message (text, line.col
#     indices, ids-as-opaque-strings, removed text).
#
# When an op eventually needs a non-string leaf (a number, a nested object, an
# array), that op declares its shape — we do not guess types from Tcl values.
# Inbound parsing uses tcllib's json::json2dict, which is unambiguous.

namespace eval rio::wire {
	# The JSON string-escape map: the two metachars, the short escapes, and a
	# \uXXXX for every remaining C0 control — RFC 8259 requires ALL of 0x00-0x1F
	# escaped. Rare in practice, but an editor meets them (an ESC in a log file, a
	# US-separated data file), and while tcllib's parser happens to tolerate them
	# raw, a strict parser rejects the whole line — and D2's promise is that any
	# language can sit at the far end of the channel. Built once at source time.
	variable strmap [list \\ \\\\ \" \\\"]
	for {set c 0} {$c < 32} {incr c} {
		switch -- $c {
			8       { lappend strmap \b \\b }
			9       { lappend strmap \t \\t }
			10      { lappend strmap \n \\n }
			12      { lappend strmap \f \\f }
			13      { lappend strmap \r \\r }
			default { lappend strmap [format %c $c] [format {\u%04x} $c] }
		}
	}
	unset c
}

# A JSON string literal.
proc rio::wire::str {s} {
	variable strmap
	return "\"[string map $strmap $s]\""
}

# A flat Tcl dict -> a JSON object with string values.
proc rio::wire::obj {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[str $k]:[str $v]" }
	return "{[join $parts ,]}"
}

# A JSON array from a list of already-encoded JSON fragments. The caller decides
# how each element is shaped (with str/obj/arr) — keeping the "no guessing from
# Tcl values" rule (D25): arr never inspects what it joins.
proc rio::wire::arr {items} {
	return "\[[join $items ,]\]"
}

# A JSON array of strings — the common case of arr, where each element is a
# string leaf (the caller declares it's strings, so str applies to each).
proc rio::wire::strarr {items} {
	set out {}
	foreach s $items { lappend out [str $s] }
	return [arr $out]
}

# A JSON object whose VALUES are each encoded by `cmd` (a command prefix taking
# one value). Lets an op declare "object of <shape>" — e.g. an object of objects
# — without the encoder guessing the shape from Tcl values (D25).
proc rio::wire::objmap {d cmd} {
	set parts {}
	dict for {k v} $d { lappend parts "[str $k]:[{*}$cmd $v]" }
	return "{[join $parts ,]}"
}

# Result-shape registry. Almost every result is a flat object (obj), which is
# exact for string leaves. The few ops with a richer result — an array, a nested
# object — register an encoder here, keyed by op name (D25: the op declares its
# shape, the encoder is told it rather than inferring it). `response` consults
# this and falls back to obj.
namespace eval rio::wire { variable results {} }

proc rio::wire::result_encoder {op cmd} {
	variable results
	dict set results $op $cmd
}

# buffer.list: result is {buffers <array of flat objects>}.
proc rio::wire::_result_buffer_list {result} {
	set items {}
	foreach b [dict get $result buffers] { lappend items [obj $b] }
	return "{\"buffers\":[arr $items]}"
}
rio::wire::result_encoder buffer.list rio::wire::_result_buffer_list

# buffer.matches: `count` is a string leaf; `matches` is an array of flat objects.
proc rio::wire::_result_buffer_matches {result} {
	set items {}
	foreach m [dict get $result matches] { lappend items [obj $m] }
	return "{\"count\":[str [dict get $result count]],\"matches\":[arr $items]}"
}
rio::wire::result_encoder buffer.matches rio::wire::_result_buffer_matches

# buffers.stale: result is {stale <array of flat objects>} (D94).
proc rio::wire::_result_buffers_stale {result} {
	set items {}
	foreach s [dict get $result stale] { lappend items [obj $s] }
	return "{\"stale\":[arr $items]}"
}
rio::wire::result_encoder buffers.stale rio::wire::_result_buffers_stale

# buffers.reload: two arrays of flat objects — what reloaded, and what could not.
proc rio::wire::_result_buffers_reload {result} {
	set done {}   ; foreach r [dict get $result reloaded] { lappend done [obj $r] }
	set failed {} ; foreach f [dict get $result failed]   { lappend failed [obj $f] }
	return "{\"reloaded\":[arr $done],\"failed\":[arr $failed]}"
}
rio::wire::result_encoder buffers.reload rio::wire::_result_buffers_reload

# The two-level search result (project.search / buffers.search, D51/D52) — the
# only two-level shape in the protocol, so the encoder spells BOTH levels out
# rather than guessing them from Tcl values (D25). The envelope (count / files /
# truncated string leaves + a `results` array) and each line-match object
# {line, col, cols, text} are shared; the two ops differ only in the per-file
# header keys, so each supplies its own header encoder.

# One line-match {line,col,cols,lens,text} object. `cols`/`lens` are parallel
# arrays — each hit's 1-based start column and its char length (a variable-length
# regex hit highlights correctly; D52 Phase C).
proc rio::wire::_linematch {m} {
	set cols {} ; foreach c [dict get $m cols] { lappend cols [str $c] }
	set lens {} ; foreach l [dict get $m lens] { lappend lens [str $l] }
	return "{\"line\":[str [dict get $m line]],\"col\":[str [dict get $m col]],\"cols\":[arr $cols],\"lens\":[arr $lens],\"text\":[str [dict get $m text]]}"
}

# The {count, files, truncated, results} envelope, given the already-encoded
# per-file objects.
proc rio::wire::_search_envelope {result fileobjs} {
	set parts {}
	lappend parts "\"count\":[str [dict get $result count]]"
	lappend parts "\"files\":[str [dict get $result files]]"
	lappend parts "\"truncated\":[str [dict get $result truncated]]"
	lappend parts "\"results\":[arr $fileobjs]"
	return "{[join $parts ,]}"
}

# project.search: each file object carries `path` + `rel` (the disk path and its
# root-relative form) alongside the nested `matches` array.
proc rio::wire::_result_project_search {result} {
	set files {}
	foreach f [dict get $result results] {
		set ms {}
		foreach m [dict get $f matches] { lappend ms [_linematch $m] }
		lappend files "{\"path\":[str [dict get $f path]],\"rel\":[str [dict get $f rel]],\"matches\":[arr $ms]}"
	}
	return [_search_envelope $result $files]
}
rio::wire::result_encoder project.search rio::wire::_result_project_search

# buffers.search: each file object carries the open buffer's `buffer` id, `name`,
# and `path` ("" for an unsaved scratch) alongside the nested `matches` array.
proc rio::wire::_result_buffers_search {result} {
	set files {}
	foreach f [dict get $result results] {
		set ms {}
		foreach m [dict get $f matches] { lappend ms [_linematch $m] }
		lappend files "{\"buffer\":[str [dict get $f buffer]],\"name\":[str [dict get $f name]],\"path\":[str [dict get $f path]],\"matches\":[arr $ms]}"
	}
	return [_search_envelope $result $files]
}
rio::wire::result_encoder buffers.search rio::wire::_result_buffers_search

# project.replace: count/files are string leaves; `bufferids` is an array of id
# strings (the open buffers that were edited, D52 Phase B).
proc rio::wire::_result_project_replace {result} {
	set parts {}
	lappend parts "\"count\":[str [dict get $result count]]"
	lappend parts "\"files\":[str [dict get $result files]]"
	lappend parts "\"bufferids\":[strarr [dict get $result bufferids]]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder project.replace rio::wire::_result_project_replace

# session.hello: {protocol, name, version, fsroot} are string leaves; `ops` is an
# array of strings. Note that this encoder is an ALLOW-LIST — a key the op returns and
# this proc does not name simply never reaches the wire. So "additive, no protocol
# bump" (D55, D123) still means editing here; the greeting's own tests are what catch
# forgetting to.
proc rio::wire::_result_session_hello {result} {
	set parts {}
	lappend parts "\"protocol\":[str [dict get $result protocol]]"
	lappend parts "\"name\":[str [dict get $result name]]"
	lappend parts "\"version\":[str [dict get $result version]]"
	lappend parts "\"ops\":[strarr [dict get $result ops]]"
	lappend parts "\"fsroot\":[str [dict get $result fsroot]]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder session.hello rio::wire::_result_session_hello

# git.status: `branch` is a string leaf; `changes` is an array of flat objects.
proc rio::wire::_result_git_status {result} {
	set items {}
	foreach c [dict get $result changes] { lappend items [obj $c] }
	return "{\"branch\":[str [dict get $result branch]],\"changes\":[arr $items]}"
}
rio::wire::result_encoder git.status rio::wire::_result_git_status

# git.log: `commits` is an array of flat objects.
proc rio::wire::_result_git_log {result} {
	set items {}
	foreach c [dict get $result commits] { lappend items [obj $c] }
	return "{\"commits\":[arr $items]}"
}
rio::wire::result_encoder git.log rio::wire::_result_git_log

# fs.list: `path` is a string leaf; `entries` is an array of flat objects.
proc rio::wire::_result_fs_list {result} {
	set items {}
	foreach e [dict get $result entries] { lappend items [obj $e] }
	return "{\"path\":[str [dict get $result path]],\"entries\":[arr $items]}"
}
rio::wire::result_encoder fs.list rio::wire::_result_fs_list

# theme.get: `colors` is a flat object; `fonts` is an object OF flat objects.
proc rio::wire::_result_theme_get {result} {
	set parts {}
	lappend parts "\"colors\":[obj [dict get $result colors]]"
	lappend parts "\"fonts\":[objmap [dict get $result fonts] rio::wire::obj]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder theme.get rio::wire::_result_theme_get

# theme.list: `themes` is an array of name strings.
proc rio::wire::_result_theme_list {result} {
	return "{\"themes\":[strarr [dict get $result themes]]}"
}
rio::wire::result_encoder theme.list rio::wire::_result_theme_list

# diff.lines: `ops` is an array of flat {tag, a, b} objects.
proc rio::wire::_result_diff_lines {result} {
	set items {}
	foreach o [dict get $result ops] { lappend items [obj $o] }
	return "{\"ops\":[arr $items]}"
}
rio::wire::result_encoder diff.lines rio::wire::_result_diff_lines

# agent.history: `messages` is an array of flat {role, text} objects.
proc rio::wire::_result_agent_history {result} {
	set items {}
	foreach m [dict get $result messages] { lappend items [obj $m] }
	return "{\"messages\":[arr $items]}"
}
rio::wire::result_encoder agent.history rio::wire::_result_agent_history

# agent.providers: `providers` is an array of flat {name,label,keyed,key_set,signup}
# objects.
proc rio::wire::_result_agent_providers {result} {
	set items {}
	foreach p [dict get $result providers] { lappend items [obj $p] }
	return "{\"providers\":[arr $items]}"
}
rio::wire::result_encoder agent.providers rio::wire::_result_agent_providers

# agent.prompt.list: `prompts` is an array of flat {which,name,path,origin,exists,
# builtin,active,chars} objects — the system prompt's layers in composition order (D105).
proc rio::wire::_result_agent_prompt_list {result} {
	set items {}
	foreach p [dict get $result prompts] { lappend items [obj $p] }
	return "{\"prompts\":[arr $items]}"
}
rio::wire::result_encoder agent.prompt.list rio::wire::_result_agent_prompt_list

# agent.options.list: `options` is an array of option objects, each carrying its own
# `choices` array — the protocol's second two-level shape (D106), so like the search
# results it spells BOTH levels out rather than guessing them from Tcl values (D25).
proc rio::wire::_option {o} {
	set cs {}
	foreach c [dict get $o choices] { lappend cs [obj $c] }
	set parts {}
	foreach k {name label hint value free refresh} {
		lappend parts "[str $k]:[str [dict get $o $k]]"
	}
	lappend parts "\"choices\":[arr $cs]"
	return "{[join $parts ,]}"
}
proc rio::wire::_result_agent_options_list {result} {
	set items {}
	foreach o [dict get $result options] { lappend items [_option $o] }
	return "{\"provider\":[str [dict get $result provider]],\"options\":[arr $items]}"
}
rio::wire::result_encoder agent.options.list rio::wire::_result_agent_options_list

# agent.status: flat except `options`, the live {name value …} summary of whatever the
# provider declares (D106) — an object of string leaves, declared rather than inferred.
proc rio::wire::_result_agent_status {result} {
	set parts {}
	foreach k {provider auto_accept mode key_set} {
		lappend parts "[str $k]:[str [dict get $result $k]]"
	}
	lappend parts "\"options\":[obj [dict get $result options]]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder agent.status rio::wire::_result_agent_status

# agent.allow.list: `rules` is an array of rules, each rule an array of argv-prefix
# token strings (D84) — a nested string array, declared here rather than inferred.
proc rio::wire::_result_agent_allow_list {result} {
	set items {}
	foreach r [dict get $result rules] { lappend items [strarr $r] }
	return "{\"rules\":[arr $items]}"
}
rio::wire::result_encoder agent.allow.list rio::wire::_result_agent_allow_list

# provider.list: `providers` is an array of flat {name,version,source,api,loadable}
# objects (installed-on-disk providers, D66); `api_max` is a string leaf.
proc rio::wire::_result_provider_list {result} {
	set items {}
	foreach p [dict get $result providers] { lappend items [obj $p] }
	return "{\"providers\":[arr $items],\"api_max\":[str [dict get $result api_max]]}"
}
rio::wire::result_encoder provider.list rio::wire::_result_provider_list

# workspace.get: `open` and `expanded` are arrays of path strings; `active` is a
# string leaf. `expanded` is the unfolded-tree set (D89).
proc rio::wire::_result_workspace_get {result} {
	return "{\"open\":[strarr [dict get $result open]],\"active\":[str [dict get $result active]],\"expanded\":[strarr [dict get $result expanded]]}"
}
rio::wire::result_encoder workspace.get rio::wire::_result_workspace_get

# tls.inspect: string leaves, and three arrays of strings — the certificate's names, the
# problem classes, and OpenSSL's reasons (D111). Keys named, so a new one is added here.
proc rio::wire::_result_tls_inspect {result} {
	set parts {}
	foreach k {host port subject issuer not_before not_after sha256 accepted} {
		lappend parts "[str $k]:[str [dict get $result $k]]"
	}
	foreach k {names problems reasons} {
		lappend parts "[str $k]:[strarr [dict get $result $k]]"
	}
	return "{[join $parts ,]}"
}
rio::wire::result_encoder tls.inspect rio::wire::_result_tls_inspect

# tls.accepted: `exceptions` is an array of flat {host,port,sha256,subject,accepted} objects.
proc rio::wire::_result_tls_accepted {result} {
	set items {}
	foreach e [dict get $result exceptions] { lappend items [obj $e] }
	return "{\"exceptions\":[arr $items]}"
}
rio::wire::result_encoder tls.accepted rio::wire::_result_tls_accepted

# A response dict {id, ok, result|error, ?op?} -> a JSON line. `op` (present on
# ok replies) selects a shape-specific result encoder; without one, the result
# is a flat object.
proc rio::wire::response {resp} {
	variable results
	set id [str [dict get $resp id]]
	if {![dict get $resp ok]} {
		# error is a flat {code, message} object (the taxonomy, O2).
		return "{\"id\":$id,\"ok\":false,\"error\":[obj [dict get $resp error]]}"
	}
	set r [dict get $resp result]
	if {[dict exists $resp op] && [dict exists $results [dict get $resp op]]} {
		set body [[dict get $results [dict get $resp op]] $r]
	} else {
		set body [obj $r]
	}
	return "{\"id\":$id,\"ok\":true,\"result\":$body}"
}

# An event dict {event, params} -> a JSON line.
proc rio::wire::event {ev} {
	return "{\"event\":[str [dict get $ev event]],\"params\":[obj [dict get $ev params]]}"
}

# extensions/openai — the Chat Completions inference core (D8, D26).
#
# MIT, like rio (D121). The notice is in this file because an installed
# extension has no LICENSE beside it (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# The wire half of an OpenAI-compatible provider: shape the
# /v1/chat/completions request, parse its SSE stream, post delta / tool /
# done / error (rio-core/agent.tcl), as the Claude core does. The face
# (api-face.tcl) calls infer with its Bearer header and config. The
# endpoint is data, so this code drives hosted ChatGPT and a local server
# alike.
#
# Where OpenAI's wire differs from Anthropic's:
#
#   system prompt  a leading {role:"system"} message, no top-level field
#   tool call      a `tool_calls` entry; its `arguments` is a JSON string
#   tool result    its own {role:"tool", tool_call_id} message
#   stream         `data:` lines of choice deltas, ended by `data: [DONE]`;
#                  tool-call fragments collect by `.index`; the outcome is
#                  `finish_reason` ("tool_calls" = run the tools)
#
# The network is a seam (a `transport` command), so the tests feed it
# canned SSE bytes. Event-loop driven (D10), Tk-free (D1). JSON and HTTPS
# are rio::llm::*, shared with the Claude extension.

package require json

namespace eval rio::openai {
	variable seq 0
	variable buf     ;# sid -> SSE line buffer (bytes not yet split into lines)
	variable raw     ;# sid -> full raw body (kept for error detail on a non-2xx)
	variable cb      ;# sid -> the provider `post` callback for this stream
	variable fin     ;# sid -> 1 once a terminal event (done/error) was posted
	variable finish  ;# sid -> the choice's finish_reason ("" until one arrives)
	variable tcalls  ;# sid -> dict: tool-call index -> {id .. name .. args ..}
	variable retry   ;# sid -> {conf conversation tools auth transport}: a one-shot re-send
	variable think   ;# sid -> 1 if this stream's reasoning is shown (the face's setting)
}

# tcllib's json decodes JSON null to the string "null". OpenAI sends
# content:null and finish_reason:null all the time, so "null" counts as
# absent. The cost: a content fragment that is exactly "null" is dropped.
proc rio::openai::_nn {v} { return [expr {$v eq "null" ? "" : $v}] }

# Start one streaming completion and return at once; the transport's
# callbacks finish the turn.
#
#   conf       messages_url, model, token_param, max_tokens, ?system?,
#              ?effort_json? (D106), ?request_timeout?, ?extra_json? (the
#              user's fields, checked by the face), ?reasoning? (show|hide)
#   auth       {header value}: Authorization "Bearer <key>", or empty
#   transport  called as {*}$transport request on_chunk on_done
#   post       the agent's provider callback
proc rio::openai::infer {conf conversation tools auth transport post} {
	variable seq ; variable buf ; variable raw ; variable cb ; variable fin
	variable finish ; variable tcalls ; variable retry ; variable think
	set sid [incr seq]
	set buf($sid) "" ; set raw($sid) "" ; set cb($sid) $post ; set fin($sid) 0
	set finish($sid) "" ; set tcalls($sid) [dict create]
	# Absent means show.
	set think($sid) [expr {![dict exists $conf reasoning]
		|| [dict get $conf reasoning] ne "hide"}]
	# All it takes to send this turn again: _done retries a 400 it can
	# repair (D106c).
	set retry($sid) [list $conf $conversation $tools $auth $transport]
	set headers [list Content-Type application/json]
	lappend headers {*}$auth
	set req [dict create \
		url     [dict get $conf messages_url] \
		headers $headers \
		body    [_request_json $conf $conversation $tools]]
	if {[dict exists $conf request_timeout]} {
		dict set req timeout [dict get $conf request_timeout]
	}
	{*}$transport $req [list rio::openai::_chunk $sid] [list rio::openai::_done $sid]
	return
}

# --- request shaping ---------------------------------------------------------

# The conversation -> the request body. The token-cap key is data
# (`token_param`, D26); the face says which a model wants.
proc rio::openai::_request_json {conf conversation tools} {
	set parts {}
	lappend parts "\"model\":[rio::llm::jstr [dict get $conf model]]"
	lappend parts "\"[dict get $conf token_param]\":[dict get $conf max_tokens]"
	lappend parts "\"stream\":true"
	lappend parts "\"messages\":\[[join [_messages_json $conf $conversation] ,]\]"
	# The effort (D106), spelled by the face. Empty by default: gpt-4o and
	# local servers reject `reasoning_effort`.
	if {[dict exists $conf effort_json] && [dict get $conf effort_json] ne ""} {
		lappend parts [dict get $conf effort_json]
	}
	if {[llength $tools]} {
		set tj {}
		foreach t $tools {
			lappend tj "{\"type\":\"function\",\"function\":{\"name\":[rio::llm::jstr [dict get $t name]],\"description\":[rio::llm::jstr [dict get $t description]],\"parameters\":[dict get $t input_schema]}}"
		}
		lappend parts "\"tools\":\[[join $tj ,]\]"
	}
	# The user's own fields (temperature, chat_template_kwargs, ...),
	# spliced raw and last. The face checked that it is an object with no
	# key rio sends, so no key appears twice.
	if {[dict exists $conf extra_json]} {
		set x [string trim [dict get $conf extra_json]]
		set inner [string trim [string range $x 1 end-1]]
		if {$inner ne ""} { lappend parts $inner }
	}
	# jascii last, over the whole body: input_schema and extra_json are
	# spliced raw, not through jstr. The HTTP layer needs pure ASCII; see
	# rio::llm::jascii.
	return [rio::llm::jascii "{[join $parts ,]}"]
}

# One rio entry can become several OpenAI messages:
#
#   system prompt (D34)      {role:"system"}, first
#   assistant turn           one message: text as `content`, tool_use
#                            blocks as `tool_calls`
#   user turn, tool_results  one {role:"tool"} each, emitted first, so they
#                            follow the tool_calls they answer
#   user turn, text          {role:"user"}
proc rio::openai::_messages_json {conf conversation} {
	set msgs {}
	if {[dict exists $conf system] && [dict get $conf system] ne ""} {
		lappend msgs "{\"role\":\"system\",\"content\":[rio::llm::jstr [dict get $conf system]]}"
	}
	foreach m $conversation {
		set role [dict get $m role]
		if {![dict exists $m content]} {
			lappend msgs "{\"role\":[rio::llm::jstr $role],\"content\":[rio::llm::jstr [dict get $m text]]}"
			continue
		}
		set text ""
		set toolcalls {}
		set toolresults {}
		foreach b [dict get $m content] {
			switch -- [dict get $b type] {
				text { append text [dict get $b text] }
				tool_use {
					# `arguments` is a JSON string: serialise the parsed input to
					# an object, then escape that as a string. The parsed input,
					# not the streamed fragments, as in the Claude core.
					lappend toolcalls "{\"id\":[rio::llm::jstr [dict get $b id]],\"type\":\"function\",\"function\":{\"name\":[rio::llm::jstr [dict get $b name]],\"arguments\":[rio::llm::jstr [rio::llm::obj_json [dict get $b input]]]}}"
				}
				tool_result {
					lappend toolresults "{\"role\":\"tool\",\"tool_call_id\":[rio::llm::jstr [dict get $b tool_use_id]],\"content\":[rio::llm::jstr [dict get $b content]]}"
				}
			}
		}
		foreach tr $toolresults { lappend msgs $tr }
		if {$role eq "assistant"} {
			set p "\"role\":\"assistant\""
			# Tool calls only: content is null. OpenAI wants the field present.
			if {$text eq "" && [llength $toolcalls]} {
				append p ",\"content\":null"
			} else {
				append p ",\"content\":[rio::llm::jstr $text]"
			}
			if {[llength $toolcalls]} { append p ",\"tool_calls\":\[[join $toolcalls ,]\]" }
			lappend msgs "{$p}"
		} elseif {$text ne "" || ![llength $toolresults]} {
			# A user turn of tool_results only adds no user message.
			lappend msgs "{\"role\":[rio::llm::jstr $role],\"content\":[rio::llm::jstr $text]}"
		}
	}
	return $msgs
}

# --- streaming SSE -> agent events -------------------------------------------
# Buffer each chunk, split it into lines, act on each `data:` line.
proc rio::openai::_chunk {sid bytes} {
	variable buf ; variable raw ; variable cb
	if {![info exists cb($sid)]} return
	append raw($sid) $bytes
	append buf($sid) $bytes
	while {[set nl [string first "\n" $buf($sid)]] >= 0} {
		set line [string range $buf($sid) 0 [expr {$nl - 1}]]
		set buf($sid) [string range $buf($sid) [expr {$nl + 1}] end]
		_line $sid [string trimright $line "\r"] $cb($sid)
	}
}

proc rio::openai::_line {sid line postcmd} {
	variable fin ; variable finish ; variable tcalls ; variable think
	if {![string match "data:*" $line]} return
	set payload [string trim [string range $line 5 end]]
	if {$payload eq ""} return
	if {$payload eq {[DONE]}} { _flush_terminal $sid $postcmd ; return }
	if {[catch {json::json2dict $payload} d]} {
		set fin($sid) 1
		{*}$postcmd error bad_response "The LLM sent a stream event rio couldn't parse — the integration may need an update"
		return
	}
	# Some compatible servers stream an error object instead of a non-2xx.
	if {[dict exists $d error]} {
		lassign [_classify_error [dict get $d error]] code msg
		set fin($sid) 1
		{*}$postcmd error $code $msg
		return
	}
	if {![dict exists $d choices]} return
	set choice [lindex [dict get $d choices] 0]
	if {$choice eq ""} return
	if {[dict exists $choice delta]} {
		set delta [dict get $choice delta]
		if {[dict exists $delta content]} {
			set c [_nn [dict get $delta content]]
			if {$c ne ""} { {*}$postcmd delta $c }
		}
		# Reasoning, streamed beside or instead of content. llama.cpp, vLLM
		# and DeepSeek say `reasoning_content`, others `reasoning`; the first
		# non-empty wins. Posted as `thinking`, never `delta`: the core shows
		# it and does not record it, so it is never sent back
		# (provider-api 4).
		if {$think($sid)} {
			set r ""
			foreach k {reasoning_content reasoning} {
				if {[dict exists $delta $k]} {
					set r [_nn [dict get $delta $k]]
					if {$r ne ""} break
				}
			}
			if {$r ne ""} { {*}$postcmd thinking $r }
		}
		if {[dict exists $delta tool_calls]} {
			foreach tc [dict get $delta tool_calls] { _accumulate $sid $tc }
		}
	}
	if {[dict exists $choice finish_reason]} {
		set fr [_nn [dict get $choice finish_reason]]
		if {$fr ne ""} { set finish($sid) $fr }
	}
}

# Fold one tool_call fragment into the collector, by its `.index`. The
# first fragment has `.id` and `.function.name`; later ones append
# `.function.arguments`.
proc rio::openai::_accumulate {sid tc} {
	variable tcalls
	set idx [expr {[dict exists $tc index] ? [dict get $tc index] : 0}]
	set cur [expr {[dict exists $tcalls($sid) $idx] ? [dict get $tcalls($sid) $idx] \
		: [dict create id "" name "" args ""]}]
	if {[dict exists $tc id]}            { dict set cur id   [_nn [dict get $tc id]] }
	if {[dict exists $tc function name]} { dict set cur name [_nn [dict get $tc function name]] }
	if {[dict exists $tc function arguments]} {
		dict append cur args [dict get $tc function arguments]
	}
	dict set tcalls($sid) $idx $cur
}

# The stream ended ([DONE], or a clean close): post each collected tool
# call, then `done tool_use` if tools were asked for, else `done`. Runs
# once per stream (fin).
proc rio::openai::_flush_terminal {sid postcmd} {
	variable fin ; variable finish ; variable tcalls
	if {![info exists fin($sid)] || $fin($sid)} return
	set fin($sid) 1
	set calls {}
	foreach idx [lsort -integer [dict keys $tcalls($sid)]] {
		lappend calls [dict get $tcalls($sid) $idx]
	}
	if {$finish($sid) eq "tool_calls" || [llength $calls]} {
		foreach c $calls {
			set rawargs [expr {[dict get $c args] eq "" ? "{}" : [dict get $c args]}]
			if {[catch {json::json2dict $rawargs} input]} { set input {} }
			{*}$postcmd tool [dict get $c id] [dict get $c name] $input $rawargs
		}
		{*}$postcmd done tool_use
	} else {
		{*}$postcmd done
	}
}

# The transport finished. With no terminal event yet: a clean 2xx still
# ends the turn; anything else becomes an agent.error that names the next
# step (D26).
proc rio::openai::_done {sid status err} {
	variable buf ; variable raw ; variable cb ; variable fin ; variable finish
	variable tcalls ; variable retry ; variable think
	if {![info exists cb($sid)]} return
	set postcmd $cb($sid)
	if {!$fin($sid) && $status == 400 && [_repair_400 $sid $postcmd]} {
		# The turn was sent again, repaired; its own _done reports. Nothing
		# is posted for this attempt.
		unset -nocomplain buf($sid) raw($sid) cb($sid) fin($sid) finish($sid) \
			tcalls($sid) retry($sid) think($sid)
		return
	}
	if {!$fin($sid)} {
		if {$status == 0} {
			if {[string match {*can't find package tls*} $err]} {
				{*}$postcmd error tls_unavailable \
					"The core can't load the TLS library the LLM's HTTPS needs — install tcltls where the core runs (apt/apk: tcl-tls; OpenBSD: tcltls) and restart it. This is the core's host, not yours, when it's remote ($err)"
			} elseif {[string match {*the agent refused https to*} $err]} {
				# The transport refused to dial (D110). Its message says why.
				{*}$postcmd error tls_unchecked $err
			} else {
				{*}$postcmd error network "Couldn't reach the LLM — check your connection, or the server URL for a local model ($err)"
			}
		} elseif {$status >= 200 && $status < 300} {
			_flush_terminal $sid $postcmd   ;# clean close without an explicit [DONE]
		} else {
			lassign [_classify $status $raw($sid)] code msg
			{*}$postcmd error $code $msg
		}
	}
	unset -nocomplain buf($sid) raw($sid) cb($sid) fin($sid) finish($sid) tcalls($sid) \
		retry($sid) think($sid)
}

# Two request fields are per model, while rio's choice is per provider, and
# /v1/models describes neither. The 400 does, so rio learns from it
# (D106c, D106d): send the turn again, repaired, and tell the face.
#
#   token cap  "Unsupported parameter: 'max_tokens' is not supported with
#              this model. Use 'max_completion_tokens' instead."
#              (reasoning models)
#   effort     "Unrecognized request argument supplied: reasoning_effort"
#              (gpt-4o, most local servers)
#
# A 400 comes before any generation, so a repair costs no tokens. Each
# repair runs at most once per turn (`repaired`), so a server that refuses
# everything gets its 400 reported, not a loop.
proc rio::openai::_repair_400 {sid postcmd} {
	variable raw ; variable retry
	if {![info exists retry($sid)]} { return 0 }
	lassign $retry($sid) conf conversation tools auth transport
	set done [expr {[dict exists $conf repaired] ? [dict get $conf repaired] : {}}]
	set body $raw($sid)
	set fix ""
	if {"token" ni $done && [dict get $conf token_param] eq "max_tokens"
			&& [string match {*max_completion_tokens*} $body]} {
		set fix token
	} elseif {"effort" ni $done && [dict exists $conf effort_json]
			&& [dict get $conf effort_json] ne ""
			&& [string match {*reasoning_effort*} $body]} {
		set fix effort
	}
	if {$fix eq ""} { return 0 }
	lappend done $fix
	dict set conf repaired $done
	switch -- $fix {
		token {
			dict set conf token_param max_completion_tokens
			_learned $conf token_learn [dict get $conf model] max_completion_tokens
		}
		effort {
			# Drop the field for this turn. The user's choice stays: support
			# is per model, and another model may take it (D106a).
			dict set conf effort_json ""
			_learned $conf effort_learn [dict get $conf model] ""
		}
	}
	infer $conf $conversation $tools $auth $transport $postcmd
	return 1
}

# Tell the face what the server taught; saving is the face's business.
# Never fatal: a working turn must not fail on bookkeeping.
proc rio::openai::_learned {conf key model value} {
	if {![dict exists $conf $key] || [dict get $conf $key] eq ""} return
	catch {{*}[dict get $conf $key] $model $value}
}

# An HTTP status, and the JSON error body if any -> {code message}. Each
# message names the next step and says "the LLM": a local-server user has
# no OpenAI key to check (D26).
proc rio::openai::_classify {status raw} {
	set detail ""
	catch {
		set d [json::json2dict $raw]
		if {[dict exists $d error message]} { set detail ": [dict get $d error message]" }
	}
	if {$status == 401 || $status == 403} {
		return [list auth "The LLM rejected the credentials (HTTP $status) — check your API key (Extensions ▸ OpenAI-compatible…), or that a local server needs none$detail"]
	} elseif {$status == 429} {
		return [list rate_limit "Rate limited by the LLM (HTTP $status) — wait a moment and retry$detail"]
	} elseif {$status >= 500} {
		return [list server "The LLM is unavailable right now (HTTP $status) — try again shortly$detail"]
	}
	return [list unexpected "The LLM replied in a way rio didn't expect (HTTP $status) — the integration may need an update$detail"]
}

# A streamed {error {...}} object -> {code message}.
proc rio::openai::_classify_error {err} {
	set msg "The LLM reported an error"
	catch {set msg [dict get $err message]}
	set code stream_error
	catch {set code [dict get $err type]}
	if {$code eq ""} { set code stream_error }
	return [list $code $msg]
}

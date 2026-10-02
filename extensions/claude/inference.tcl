# extensions/claude — the Claude inference core (D8, D26).
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
# The part of a Claude provider that does not depend on how you
# authenticate:
#
#   request   shape the Messages API body
#   response  parse the SSE stream
#   events    post delta / tool / done / error (rio-core/agent.tcl)
#   failures  classify them into messages that name the next step (D26)
#
# The face (api-face.tcl) calls infer with its auth header and config. The
# network is a seam: infer takes a `transport` command, so the tests feed
# it canned SSE bytes. Event-loop driven (D10), Tk-free (D1).

package require json

namespace eval rio::claude {
	variable seq 0
	variable buf    ;# sid -> SSE line buffer (bytes not yet split into lines)
	variable raw    ;# sid -> full raw body (kept for error detail on a non-200)
	variable cb     ;# sid -> the provider `post` callback for this stream
	variable fin    ;# sid -> 1 once a terminal event (done/error) was posted
	variable stop   ;# sid -> the message's stop_reason ("" until message_delta)
	variable cbtype ;# sid -> the current content block's type (text|tool_use)
	variable tuid   ;# sid -> current tool_use block id
	variable tuname ;# sid -> current tool_use block name
	variable tujson ;# sid -> accumulated input_json_delta for the current tool_use
}

# Start one streaming completion and return at once; the transport's
# callbacks finish the turn.
#
#   conf       messages_url, anthropic_version, ?anthropic_beta?, model,
#              max_tokens, ?system?, ?effort_json? (D106), ?request_timeout?
#   auth       {header value}: x-api-key <key>
#   transport  called as {*}$transport request on_chunk on_done
#                request   {url headers body ?timeout?}
#                on_chunk  one chunk of the response body
#                on_done   {status err}; status 0 = could not connect
#   post       the agent's provider callback
proc rio::claude::infer {conf conversation tools auth transport post} {
	variable seq ; variable buf ; variable raw ; variable cb ; variable fin
	variable stop ; variable cbtype ; variable tujson
	set sid [incr seq]
	set buf($sid) "" ; set raw($sid) "" ; set cb($sid) $post ; set fin($sid) 0
	set stop($sid) "" ; set cbtype($sid) text ; set tujson($sid) ""
	set headers [list \
		Content-Type      application/json \
		anthropic-version [dict get $conf anthropic_version]]
	if {[dict exists $conf anthropic_beta] && [dict get $conf anthropic_beta] ne ""} {
		lappend headers anthropic-beta [dict get $conf anthropic_beta]
	}
	lappend headers {*}$auth
	set req [dict create \
		url     [dict get $conf messages_url] \
		headers $headers \
		body    [_request_json $conf $conversation $tools]]
	# Pass a timeout only if one is configured; the transport has its own
	# default.
	if {[dict exists $conf request_timeout]} {
		dict set req timeout [dict get $conf request_timeout]
	}
	{*}$transport $req [list rio::claude::_chunk $sid] [list rio::claude::_done $sid]
	return
}

# --- request shaping ---------------------------------------------------------
# agent.tcl's conversation, a list of {role content}, becomes Claude
# messages; each `content` is a block array. `tools` is the agent's tool
# specs: {name description input_schema}.
proc rio::claude::_request_json {conf conversation tools} {
	set msgs {}
	foreach m $conversation {
		lappend msgs "{\"role\":[rio::llm::jstr [dict get $m role]],\"content\":[_content_json $m]}"
	}
	set parts {}
	lappend parts "\"model\":[rio::llm::jstr [dict get $conf model]]"
	lappend parts "\"max_tokens\":[dict get $conf max_tokens]"
	lappend parts "\"stream\":true"
	lappend parts "\"messages\":\[[join $msgs ,]\]"
	if {[dict exists $conf system] && [dict get $conf system] ne ""} {
		lappend parts "\"system\":[rio::llm::jstr [dict get $conf system]]"
	}
	# The effort (D106), spelled by the face. Empty by default.
	if {[dict exists $conf effort_json] && [dict get $conf effort_json] ne ""} {
		lappend parts [dict get $conf effort_json]
	}
	if {[llength $tools]} {
		set tj {}
		foreach t $tools {
			lappend tj "{\"name\":[rio::llm::jstr [dict get $t name]],\"description\":[rio::llm::jstr [dict get $t description]],\"input_schema\":[dict get $t input_schema]}"
		}
		lappend parts "\"tools\":\[[join $tj ,]\]"
	}
	# jascii last, over the whole body: a tool's input_schema is spliced
	# raw, not through jstr. The HTTP layer needs pure ASCII; see
	# rio::llm::jascii.
	return [rio::llm::jascii "{[join $parts ,]}"]
}

# A message's content -> a JSON array of blocks. An old {role text} entry,
# with no `content`, becomes one text block.
proc rio::claude::_content_json {m} {
	if {![dict exists $m content]} {
		return "\[{\"type\":\"text\",\"text\":[rio::llm::jstr [dict get $m text]]}\]"
	}
	set blocks {}
	foreach b [dict get $m content] {
		switch -- [dict get $b type] {
			text {
				lappend blocks "{\"type\":\"text\",\"text\":[rio::llm::jstr [dict get $b text]]}"
			}
			tool_use {
				# Serialise the parsed input again; do not splice the streamed
				# JSON. Its strings are already unescaped, so a file's newlines
				# would go out raw and the API rejects the body.
				lappend blocks "{\"type\":\"tool_use\",\"id\":[rio::llm::jstr [dict get $b id]],\"name\":[rio::llm::jstr [dict get $b name]],\"input\":[rio::llm::obj_json [dict get $b input]]}"
			}
			tool_result {
				set tr "\"type\":\"tool_result\",\"tool_use_id\":[rio::llm::jstr [dict get $b tool_use_id]],\"content\":[rio::llm::jstr [dict get $b content]]"
				if {[dict exists $b is_error] && [dict get $b is_error]} {
					append tr ",\"is_error\":true"
				}
				lappend blocks "{$tr}"
			}
		}
	}
	return "\[[join $blocks ,]\]"
}

# jstr and obj_json are shared with the OpenAI core: plugins/lib/json.tcl.

# --- streaming SSE -> agent events -------------------------------------------
# Buffer each chunk, split it into lines, act on each. Anthropic puts the
# event type inside the data JSON, so only `data:` lines matter.
proc rio::claude::_chunk {sid bytes} {
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

proc rio::claude::_line {sid line postcmd} {
	variable fin ; variable stop
	variable cbtype ; variable tuid ; variable tuname ; variable tujson
	if {![string match "data:*" $line]} return
	set payload [string trim [string range $line 5 end]]
	if {$payload eq "" || $payload eq {[DONE]}} return
	if {[catch {json::json2dict $payload} d] || ![dict exists $d type]} {
		set fin($sid) 1
		{*}$postcmd error bad_response "Claude sent a stream event rio couldn't parse — the integration may need an update"
		return
	}
	switch -- [dict get $d type] {
		content_block_start {
			# A block opens. For a tool_use, keep its id and name and start
			# collecting its input JSON.
			set cbtype($sid) text
			if {[dict exists $d content_block type] &&
			    [dict get $d content_block type] eq "tool_use"} {
				set cbtype($sid) tool_use
				set tuid($sid)   [dict get $d content_block id]
				set tuname($sid) [dict get $d content_block name]
				set tujson($sid) ""
			}
		}
		content_block_delta {
			if {![dict exists $d delta type]} return
			switch -- [dict get $d delta type] {
				text_delta       { {*}$postcmd delta [dict get $d delta text] }
				input_json_delta { append tujson($sid) [dict get $d delta partial_json] }
			}
		}
		content_block_stop {
			# A tool_use block closed: parse its input and post the tool call.
			if {$cbtype($sid) eq "tool_use"} {
				set rawjson [expr {$tujson($sid) eq "" ? "{}" : $tujson($sid)}]
				if {[catch {json::json2dict $rawjson} input]} { set input {} }
				{*}$postcmd tool $tuid($sid) $tuname($sid) $input $rawjson
				set cbtype($sid) text
			}
		}
		message_delta {
			# Carries the stop_reason; "tool_use" means more work follows.
			catch {set stop($sid) [dict get $d delta stop_reason]}
		}
		error {
			set code stream_error ; set msg "Claude reported a streaming error"
			catch {set code [dict get $d error type]}
			catch {set msg  [dict get $d error message]}
			set fin($sid) 1
			{*}$postcmd error $code $msg
		}
		message_stop {
			set fin($sid) 1
			_post_done $postcmd $stop($sid)
		}
	}
}

# Post `done`, with the stop_reason if there is one. `done tool_use` tells
# the loop to run the tools and continue.
proc rio::claude::_post_done {postcmd stop} {
	if {$stop eq ""} { {*}$postcmd done } else { {*}$postcmd done $stop }
}

# The transport finished. If no terminal event was posted yet, the HTTP
# status decides: an agent.error that names the next step (D26), with the
# API's own message when the body has one.
proc rio::claude::_done {sid status err} {
	variable buf ; variable raw ; variable cb ; variable fin ; variable stop
	variable cbtype ; variable tuid ; variable tuname ; variable tujson
	if {![info exists cb($sid)]} return
	set postcmd $cb($sid)
	if {!$fin($sid)} {
		if {$status == 0} {
			# No HTTP reply. Usually the network, but also a core without
			# tcltls (D30: the agent's HTTPS runs in the core). The fixes
			# differ, so tell them apart.
			if {[string match {*can't find package tls*} $err]} {
				{*}$postcmd error tls_unavailable \
					"The core can't load the TLS library Claude's HTTPS needs — install tcltls where the core runs (apt/apk: tcl-tls; OpenBSD: tcltls) and restart it. This is the core's host, not yours, when it's remote ($err)"
			} elseif {[string match {*the agent refused https to*} $err]} {
				# The transport refused to dial (D110). Its message says why.
				{*}$postcmd error tls_unchecked $err
			} else {
				{*}$postcmd error network "Couldn't reach Claude — check your connection ($err)"
			}
		} elseif {$status == 200} {
			_post_done $postcmd $stop($sid)   ;# clean close without an explicit message_stop
		} else {
			lassign [_classify $status $raw($sid)] code msg
			{*}$postcmd error $code $msg
		}
	}
	unset -nocomplain buf($sid) raw($sid) cb($sid) fin($sid) stop($sid) \
		cbtype($sid) tuid($sid) tuname($sid) tujson($sid)
}

# An HTTP status, and the JSON error body if any -> {code message}. Each
# message names the user's next step (D26).
proc rio::claude::_classify {status raw} {
	set detail ""
	catch {
		set d [json::json2dict $raw]
		if {[dict exists $d error message]} { set detail ": [dict get $d error message]" }
	}
	if {$status == 401 || $status == 403} {
		return [list auth "Claude rejected the credentials (HTTP $status) — check your API key (Extensions ▸ Claude…)$detail"]
	} elseif {$status == 429} {
		return [list rate_limit "Rate limited by Claude (HTTP $status) — wait a moment and retry$detail"]
	} elseif {$status >= 500} {
		return [list server "Claude is unavailable right now (HTTP $status) — try again shortly$detail"]
	}
	return [list unexpected "Claude replied in a way rio didn't expect (HTTP $status) — the integration may need an update$detail"]
}

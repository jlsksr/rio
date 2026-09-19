# extensions/claude — the shared Claude inference core (AGENTS.md D8, D26).
#
# MIT-licensed, like rio itself (D121). The notice is IN this file because an installed
# extension travels alone: rio writes the payload into your extension directory, and there
# is no LICENSE beside it there (D122).
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
# The ~80% of a Claude provider that is identical whichever way you authenticate:
# shaping the Messages-API request, parsing the streaming SSE response, mapping
# Claude's output onto the agent provider vocabulary (post delta/tool/done/error,
# see rio-core/agent.tcl), and classifying failures into helpful, actionable
# messages (the D26 resilience requirement). The auth face (claude-api) calls
# infer with its own auth header + config; nothing here knows how the credential
# was obtained — the split keeps room for other auth strategies without rewriting
# this core.
#
# The network itself is a seam: infer is handed a `transport` command, so this
# module is fully testable against canned SSE bytes with no HTTPS (the real
# tcltls transport is wired in step 3). Event-loop driven (D10), Tk-free (D1).

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

# Start one streaming completion. `conf` carries the config-as-data (D26):
# messages_url, anthropic_version, anthropic_beta, model, max_tokens, ?system?,
# ?effort_json? (the face's already-spelled effort fragment, D106), ?request_timeout?.
# `auth` is a {header value} pair the face supplies (x-api-key <key> for the
# API face). `transport` is `{*}$transport request on_chunk on_done`:
#   request  = {url, headers, body, ?timeout?}
#   on_chunk = invoked with each response body chunk (bytes)
#   on_done  = invoked {status err}: HTTP status (0 = couldn't connect), err text
# `post` is the agent provider callback. Returns immediately; the turn completes
# asynchronously as the transport drives the callbacks.
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
	# Forward the request-timeout budget only when configured; the transport keeps
	# a generous default otherwise (D26: the wire specifics are data, not code).
	if {[dict exists $conf request_timeout]} {
		dict set req timeout [dict get $conf request_timeout]
	}
	{*}$transport $req [list rio::claude::_chunk $sid] [list rio::claude::_done $sid]
	return
}

# --- request shaping ---------------------------------------------------------
# The conversation is agent.tcl's list of {role, content} dicts -> Claude messages,
# each `content` a block array (text / tool_use / tool_result). `tools` is the
# agent's tool specs ({name, description, input_schema}); when present they ride
# along so the model can request a read (D26 slice 4).
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
	# The effort choice (D106), already spelled as a JSON fragment by the face — or
	# empty, which is the default and means the request is byte-for-byte the one rio
	# has always sent.
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
	# jascii is the last word on the body, because not every part of it came through
	# jstr: a tool's `input_schema` is spliced raw (it is already JSON), as is a
	# tool_use block's own `raw` input. The HTTP layer is handed a pure-ASCII body or
	# it mangles what it doesn't expect — see rio::llm::jascii for what that cost.
	return [rio::llm::jascii "{[join $parts ,]}"]
}

# A message's content -> a JSON array of block objects. A legacy {role,text} entry
# (no `content`) is wrapped as a single text block, so the echo path and older
# callers keep working. tool_use re-sends Claude's own input JSON verbatim (`raw`);
# tool_result carries our captured output and an optional is_error flag.
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
				# Re-serialize the PARSED input through jstr rather than splicing the
				# raw streamed JSON: the raw fragments carry already-unescaped string
				# values (json2dict decoded them during SSE parsing), so echoing them
				# verbatim would put literal control characters (a file's newlines)
				# into the body and the API rejects it. obj_json escapes every value.
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

# Request-body string/object serialisation (jstr / obj_json) is provider-agnostic
# and now lives in the shared plugin lib (plugins/lib/json.tcl, rio::llm::*), so
# the Claude and OpenAI cores share one copy.

# --- streaming SSE -> agent events -------------------------------------------
# Each response chunk: buffer it (and the raw body), split into complete lines,
# and act on each. Anthropic's stream carries the event type INSIDE the data
# JSON, so we key off `data:` lines alone and switch on the JSON `type`.
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
			# A new content block opens. Remember its kind; for a tool_use block,
			# capture id/name and start accumulating its streamed input JSON.
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
			# A tool_use block closed — parse its accumulated input and surface the
			# tool call (raw kept verbatim so the loop can re-send Claude's own JSON).
			if {$cbtype($sid) eq "tool_use"} {
				set rawjson [expr {$tujson($sid) eq "" ? "{}" : $tujson($sid)}]
				if {[catch {json::json2dict $rawjson} input]} { set input {} }
				{*}$postcmd tool $tuid($sid) $tuname($sid) $input $rawjson
				set cbtype($sid) text
			}
		}
		message_delta {
			# Carries the stop_reason ("tool_use" means more work follows).
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

# Post the terminal `done`, carrying the stop_reason only when there is one — a
# plain completion is a bare `done` (the same shape the echo provider posts), and
# `done tool_use` tells the loop to run the requested tools and continue.
proc rio::claude::_post_done {postcmd stop} {
	if {$stop eq ""} { {*}$postcmd done } else { {*}$postcmd done $stop }
}

# Transport finished. If the stream already produced a terminal event we are
# done; otherwise classify by HTTP status into an actionable agent.error (D26),
# enriched with the API's own error message when the body carries one.
proc rio::claude::_done {sid status err} {
	variable buf ; variable raw ; variable cb ; variable fin ; variable stop
	variable cbtype ; variable tuid ; variable tuname ; variable tujson
	if {![info exists cb($sid)]} return
	set postcmd $cb($sid)
	if {!$fin($sid)} {
		if {$status == 0} {
			# Status 0 is "the transport never got an HTTP reply" — usually a real
			# connection failure, but ALSO the case where the core can't even set up
			# TLS because the tcltls package is missing (D30: the agent's HTTPS runs
			# in the core, so a TLS-less server fails here). Tell those apart — the
			# fixes are different (check the network vs. install tcltls on the core).
			if {[string match {*can't find package tls*} $err]} {
				{*}$postcmd error tls_unavailable \
					"The core can't load the TLS library Claude's HTTPS needs — install tcltls where the core runs (apt/apk: tcl-tls; OpenBSD: tcltls) and restart it. This is the core's host, not yours, when it's remote ($err)"
			} elseif {[string match {*the agent refused https to*} $err]} {
				# The transport's own refusal (D110): nothing was dialled, so the connection
				# is not what to check — the message already says what is.
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

# Map an HTTP status (+ optional JSON error body) to {code, message}. The
# messages always name the user's next action — the break-without-notice case is
# `unexpected`, told plainly. (D26.)
proc rio::claude::_classify {status raw} {
	set detail ""
	catch {
		set d [json::json2dict $raw]
		if {[dict exists $d error message]} { set detail ": [dict get $d error message]" }
	}
	if {$status == 401 || $status == 403} {
		return [list auth "Claude rejected the credentials (HTTP $status) — check your API key (Preferences ▸ Agent)$detail"]
	} elseif {$status == 429} {
		return [list rate_limit "Rate limited by Claude (HTTP $status) — wait a moment and retry$detail"]
	} elseif {$status >= 500} {
		return [list server "Claude is unavailable right now (HTTP $status) — try again shortly$detail"]
	}
	return [list unexpected "Claude replied in a way rio didn't expect (HTTP $status) — the integration may need an update$detail"]
}

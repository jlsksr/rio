# plugins/claude — the shared Claude inference core (AGENTS.md D8, D26).
#
# The ~80% of a Claude provider that is identical whichever way you authenticate:
# shaping the Messages-API request, parsing the streaming SSE response, mapping
# Claude's output onto the agent provider vocabulary (post delta/tool/done/error,
# see rio-core/agent.tcl), and classifying failures into helpful, actionable
# messages (the D26 resilience requirement). The two auth faces (claude-oauth,
# claude-api) call infer with their own auth header + config; nothing here knows
# how the credential was obtained.
#
# The network itself is a seam: infer is handed a `transport` command, so this
# module is fully testable against canned SSE bytes with no HTTPS (the real
# tcltls transport is wired in step 3). Event-loop driven (D10), Tk-free (D1).

package require json

namespace eval rio::claude {
	variable seq 0
	variable buf   ;# sid -> SSE line buffer (bytes not yet split into lines)
	variable raw   ;# sid -> full raw body (kept for error detail on a non-200)
	variable cb    ;# sid -> the provider `post` callback for this stream
	variable fin   ;# sid -> 1 once a terminal event (done/error) was posted
}

# Start one streaming completion. `conf` carries the config-as-data (D26):
# messages_url, anthropic_version, anthropic_beta, model, max_tokens, ?system?.
# `auth` is a {header value} pair the face supplies (Authorization {Bearer ..} or
# x-api-key ..). `transport` is `{*}$transport request on_chunk on_done`:
#   request  = {url, headers, body}
#   on_chunk = invoked with each response body chunk (bytes)
#   on_done  = invoked {status err}: HTTP status (0 = couldn't connect), err text
# `post` is the agent provider callback. Returns immediately; the turn completes
# asynchronously as the transport drives the callbacks.
proc rio::claude::infer {conf conversation auth transport post} {
	variable seq ; variable buf ; variable raw ; variable cb ; variable fin
	set sid [incr seq]
	set buf($sid) "" ; set raw($sid) "" ; set cb($sid) $post ; set fin($sid) 0
	set headers [list \
		Content-Type      application/json \
		anthropic-version [dict get $conf anthropic_version] \
		anthropic-beta    [dict get $conf anthropic_beta]]
	lappend headers {*}$auth
	set req [dict create \
		url     [dict get $conf messages_url] \
		headers $headers \
		body    [_request_json $conf $conversation]]
	{*}$transport $req [list rio::claude::_chunk $sid] [list rio::claude::_done $sid]
	return
}

# --- request shaping ---------------------------------------------------------
# The conversation is agent.tcl's list of {role, text} dicts -> Claude messages.
proc rio::claude::_request_json {conf conversation} {
	set msgs {}
	foreach m $conversation {
		lappend msgs "{\"role\":[_jstr [dict get $m role]],\"content\":[_jstr [dict get $m text]]}"
	}
	set parts {}
	lappend parts "\"model\":[_jstr [dict get $conf model]]"
	lappend parts "\"max_tokens\":[dict get $conf max_tokens]"
	lappend parts "\"stream\":true"
	lappend parts "\"messages\":\[[join $msgs ,]\]"
	if {[dict exists $conf system] && [dict get $conf system] ne ""} {
		lappend parts "\"system\":[_jstr [dict get $conf system]]"
	}
	return "{[join $parts ,]}"
}

# A JSON string literal: escape ", \, and all control characters (RFC 8259).
proc rio::claude::_jstr {s} {
	set out ""
	foreach ch [split $s ""] {
		scan $ch %c code
		if {$ch eq "\""} {
			append out {\"}
		} elseif {$ch eq "\\"} {
			append out {\\}
		} elseif {$code < 0x20} {
			switch -- $code {
				8  { append out {\b} }
				9  { append out {\t} }
				10 { append out {\n} }
				12 { append out {\f} }
				13 { append out {\r} }
				default { append out [format {\u%04x} $code] }
			}
		} else {
			append out $ch
		}
	}
	return "\"$out\""
}

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
	variable fin
	if {![string match "data:*" $line]} return
	set payload [string trim [string range $line 5 end]]
	if {$payload eq "" || $payload eq {[DONE]}} return
	if {[catch {json::json2dict $payload} d] || ![dict exists $d type]} {
		set fin($sid) 1
		{*}$postcmd error bad_response "Claude sent a stream event rio couldn't parse — the integration may need an update"
		return
	}
	switch -- [dict get $d type] {
		content_block_delta {
			if {[dict exists $d delta type] && [dict get $d delta type] eq "text_delta"} {
				{*}$postcmd delta [dict get $d delta text]
			}
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
			{*}$postcmd done
		}
	}
}

# Transport finished. If the stream already produced a terminal event we are
# done; otherwise classify by HTTP status into an actionable agent.error (D26),
# enriched with the API's own error message when the body carries one.
proc rio::claude::_done {sid status err} {
	variable buf ; variable raw ; variable cb ; variable fin
	if {![info exists cb($sid)]} return
	set postcmd $cb($sid)
	if {!$fin($sid)} {
		if {$status == 0} {
			{*}$postcmd error network "Couldn't reach Claude — check your connection ($err)"
		} elseif {$status == 200} {
			{*}$postcmd done    ;# clean close without an explicit message_stop
		} else {
			lassign [_classify $status $raw($sid)] code msg
			{*}$postcmd error $code $msg
		}
	}
	unset -nocomplain buf($sid) raw($sid) cb($sid) fin($sid)
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
		return [list auth "Claude rejected the sign-in (HTTP $status) — re-authenticate; the sign-in flow may have changed$detail"]
	} elseif {$status == 429} {
		return [list rate_limit "Rate limited by Claude (HTTP $status) — wait a moment and retry$detail"]
	} elseif {$status >= 500} {
		return [list server "Claude is unavailable right now (HTTP $status) — try again shortly$detail"]
	}
	return [list unexpected "Claude replied in a way rio didn't expect (HTTP $status) — the integration may need an update$detail"]
}

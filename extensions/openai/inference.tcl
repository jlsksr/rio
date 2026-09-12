# extensions/openai — the OpenAI Chat Completions inference core (AGENTS.md D8, D26).
#
# The provider-specific half of an OpenAI-compatible provider: shaping the
# /v1/chat/completions request, parsing its streaming SSE response, and mapping it
# onto the agent provider vocabulary (post delta/tool/done/error — the same
# contract the Claude core targets, see rio-core/agent.tcl). The auth face
# (api-face.tcl) calls infer with its own Bearer header + config; nothing here
# knows how the credential was obtained, and — because the endpoint is config-as-
# data — the SAME code drives hosted ChatGPT and a local OpenAI-compatible server
# (Ollama / llama-server / LM Studio / vLLM).
#
# OpenAI's wire shape differs from Anthropic's, so the mapping is its own:
#   - the system prompt is a leading {role:"system"} MESSAGE (no top-level field);
#   - an assistant tool call is a `tool_calls` entry whose `arguments` is a JSON
#     STRING; a tool result is a separate {role:"tool", tool_call_id} message;
#   - the stream is `data:` lines of choice deltas, terminated by `data: [DONE]`,
#     with tool-call fragments accumulated per `.index` and the turn's outcome in
#     `finish_reason` ("tool_calls" -> run tools; else stop).
#
# The network is a seam (a `transport` command), so this is fully testable against
# canned SSE bytes with no HTTPS. Event-loop driven (D10), Tk-free (D1). Shares the
# JSON serialisers and the HTTPS transport with the Claude plugin (rio::llm::*).

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
}

# tcllib's json decodes a JSON `null` to the STRING "null" (indistinguishable from
# the JSON string "null"). OpenAI sends content:null on role/tool-call chunks and
# finish_reason:null until the end, so we treat "null" as absent. The only cost is
# a content fragment that is literally the four characters "null" — vanishingly
# rare, and worth it to keep every tool turn from leaking a stray "null".
proc rio::openai::_nn {v} { return [expr {$v eq "null" ? "" : $v}] }

# Start one streaming completion. `conf` carries the config-as-data (D26):
# messages_url, model, token_param, max_tokens, ?system?, ?effort_json? (the face's
# already-spelled effort fragment, D106), ?request_timeout?.
# `auth` is a {header value} pair the face supplies (Authorization "Bearer <key>").
# `transport` is `{*}$transport request on_chunk on_done` (the shared rio::llm
# transport, or a test fake). `post` is the agent provider callback. Returns
# immediately; the turn completes asynchronously as the transport drives back.
proc rio::openai::infer {conf conversation tools auth transport post} {
	variable seq ; variable buf ; variable raw ; variable cb ; variable fin
	variable finish ; variable tcalls ; variable retry
	set sid [incr seq]
	set buf($sid) "" ; set raw($sid) "" ; set cb($sid) $post ; set fin($sid) 0
	set finish($sid) "" ; set tcalls($sid) [dict create]
	# Everything needed to send this turn again, for the one retry _done may make
	# when the server tells us the token-cap parameter is the other one (D106c).
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

# The conversation (agent.tcl's {role, content-block} list) -> OpenAI messages. The
# token-cap key is config-as-data (`token_param`): hosted newer models want
# `max_completion_tokens`, older ones and most local servers want `max_tokens`, so
# a model change is a one-line config edit, not a rebuild (D26).
proc rio::openai::_request_json {conf conversation tools} {
	set parts {}
	lappend parts "\"model\":[rio::llm::jstr [dict get $conf model]]"
	lappend parts "\"[dict get $conf token_param]\":[dict get $conf max_tokens]"
	lappend parts "\"stream\":true"
	lappend parts "\"messages\":\[[join [_messages_json $conf $conversation] ,]\]"
	# The effort choice (D106), already spelled by the face — empty by default, so the
	# request stays the one rio has always sent (and that gpt-4o and local servers,
	# which reject `reasoning_effort`, have always accepted).
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
	# jascii is the last word on the body, because not every part of it came through
	# jstr: a tool's `input_schema` is spliced raw (it is already JSON). The HTTP
	# layer is handed a pure-ASCII body or it mangles what it doesn't expect — see
	# rio::llm::jascii for the failure this cost live.
	return [rio::llm::jascii "{[join $parts ,]}"]
}

# One rio conversation entry can expand to SEVERAL OpenAI messages: an assistant
# turn is a single message carrying its text as `content` and its tool_use blocks
# as `tool_calls`; a user turn's tool_result blocks each become their own
# {role:"tool"} message (emitted first, so they immediately follow the assistant
# tool_calls they answer), and its text becomes a {role:"user"} message. The
# system prompt (D34) leads as a {role:"system"} message.
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
					# `arguments` is a JSON *string*: serialize the parsed input to a
					# JSON object, then escape that whole object as a string value. (Re-
					# serialize rather than splice the raw streamed fragments, for the
					# same reason the Claude core does — the fragments carry already-
					# unescaped values.)
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
			# content is null when the assistant turn is tool_calls only (OpenAI wants
			# a present content field; null is its "no prose" value).
			if {$text eq "" && [llength $toolcalls]} {
				append p ",\"content\":null"
			} else {
				append p ",\"content\":[rio::llm::jstr $text]"
			}
			if {[llength $toolcalls]} { append p ",\"tool_calls\":\[[join $toolcalls ,]\]" }
			lappend msgs "{$p}"
		} elseif {$text ne "" || ![llength $toolresults]} {
			# A user turn that is PURE tool_result adds no user message (the tool
			# messages already carry it); otherwise emit the user text.
			lappend msgs "{\"role\":[rio::llm::jstr $role],\"content\":[rio::llm::jstr $text]}"
		}
	}
	return $msgs
}

# --- streaming SSE -> agent events -------------------------------------------
# Each response chunk: buffer it (and the raw body), split into complete lines,
# and act on each `data:` line (OpenAI SSE carries only data lines).
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
	variable fin ; variable finish ; variable tcalls
	if {![string match "data:*" $line]} return
	set payload [string trim [string range $line 5 end]]
	if {$payload eq ""} return
	if {$payload eq {[DONE]}} { _flush_terminal $sid $postcmd ; return }
	if {[catch {json::json2dict $payload} d]} {
		set fin($sid) 1
		{*}$postcmd error bad_response "The LLM sent a stream event rio couldn't parse — the integration may need an update"
		return
	}
	# An in-band error object (some OpenAI-compatible servers stream one instead of
	# a non-2xx) — classify and finish.
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
		if {[dict exists $delta tool_calls]} {
			foreach tc [dict get $delta tool_calls] { _accumulate $sid $tc }
		}
	}
	if {[dict exists $choice finish_reason]} {
		set fr [_nn [dict get $choice finish_reason]]
		if {$fr ne ""} { set finish($sid) $fr }
	}
}

# Fold one streamed tool_call fragment into the accumulator keyed by its `.index`
# (the first fragment for an index carries `.id` + `.function.name`; later
# fragments append `.function.arguments`).
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

# The end of the stream ([DONE], or a clean transport close): surface any
# accumulated tool calls as `tool` posts (parsed input + raw args), then the
# terminal `done` — `done tool_use` when the model asked to run tools (so the loop
# executes them and continues), a bare `done` otherwise. Idempotent via fin.
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

# Transport finished. If the stream already produced a terminal event we are done;
# a clean 2xx that ended without an explicit [DONE] still finishes the turn;
# otherwise classify by HTTP status into an actionable agent.error (D26).
proc rio::openai::_done {sid status err} {
	variable buf ; variable raw ; variable cb ; variable fin ; variable finish
	variable tcalls ; variable retry
	if {![info exists cb($sid)]} return
	set postcmd $cb($sid)
	if {!$fin($sid) && $status == 400 && [_repair_400 $sid $postcmd]} {
		# The turn was re-sent with the other token-cap parameter; its own _done will
		# report the outcome. Nothing is posted for this attempt — the user never sees
		# a failure rio knew how to answer.
		unset -nocomplain buf($sid) raw($sid) cb($sid) fin($sid) finish($sid) \
			tcalls($sid) retry($sid)
		return
	}
	if {!$fin($sid)} {
		if {$status == 0} {
			if {[string match {*can't find package tls*} $err]} {
				{*}$postcmd error tls_unavailable \
					"The core can't load the TLS library the LLM's HTTPS needs — install tcltls where the core runs (apt/apk: tcl-tls; OpenBSD: tcltls) and restart it. This is the core's host, not yours, when it's remote ($err)"
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
		retry($sid)
}

# Two request fields are per MODEL while rio's choice of them is per PROVIDER, and
# OpenAI's /v1/models describes neither — unlike Anthropic's capabilities (D106a),
# there is nothing to ask. But the 400 says it outright, so rio lets the refusal
# teach it (D106c/D106d, jka's call): re-send the turn with the field repaired, and
# hand the answer to the face to remember for that model.
#
#   token cap — "Unsupported parameter: 'max_tokens' is not supported with this
#               model. Use 'max_completion_tokens' instead."   (reasoning models)
#   effort    — "Unrecognized request argument supplied: reasoning_effort"
#                                                    (gpt-4o, most local servers)
#
# No vendor table to rot; a server that is happy with what we sent never gets here;
# and a 400 is refused before any generation, so a repair costs no tokens. Each
# repair is attempted at most ONCE per turn (`repaired` records which have been
# applied), so a server that refuses everything reports its 400 rather than looping.
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
			# Drop the field for this turn. The user's CHOICE is left alone — support is
			# per model, so switching back to a model that takes an effort restores it
			# (the rule D106a settled for Claude).
			dict set conf effort_json ""
			_learned $conf effort_learn [dict get $conf model] ""
		}
	}
	infer $conf $conversation $tools $auth $transport $postcmd
	return 1
}

# Tell the face what the server taught us; persistence is its business, not the
# wire's. Never fatal — a turn that works must not fail on a bookkeeping error.
proc rio::openai::_learned {conf key model value} {
	if {![dict exists $conf $key] || [dict get $conf $key] eq ""} return
	catch {{*}[dict get $conf $key] $model $value}
}

# Map an HTTP status (+ optional JSON error body) to {code, message}. Messages
# name the user's next action, and stay generic about the service ("the LLM") so a
# local-server user isn't told to check an OpenAI key (D26).
proc rio::openai::_classify {status raw} {
	set detail ""
	catch {
		set d [json::json2dict $raw]
		if {[dict exists $d error message]} { set detail ": [dict get $d error message]" }
	}
	if {$status == 401 || $status == 403} {
		return [list auth "The LLM rejected the credentials (HTTP $status) — check your API key (Preferences ▸ Agent), or that a local server needs none$detail"]
	} elseif {$status == 429} {
		return [list rate_limit "Rate limited by the LLM (HTTP $status) — wait a moment and retry$detail"]
	} elseif {$status >= 500} {
		return [list server "The LLM is unavailable right now (HTTP $status) — try again shortly$detail"]
	}
	return [list unexpected "The LLM replied in a way rio didn't expect (HTTP $status) — the integration may need an update$detail"]
}

# An in-band {error {...}} streamed object -> {code, message} (some compatible
# servers report failures this way rather than via HTTP status).
proc rio::openai::_classify_error {err} {
	set msg "The LLM reported an error"
	catch {set msg [dict get $err message]}
	set code stream_error
	catch {set code [dict get $err type]}
	if {$code eq ""} { set code stream_error }
	return [list $code $msg]
}

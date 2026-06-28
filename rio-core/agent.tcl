# rio-core — the agent orchestration loop (AGENTS.md D20, D26).
#
# The durable, core-owned half of the agent: it owns the conversation state and
# the orchestration loop, and drives a *provider* (D8) which absorbs one LLM
# service's wire specifics. The loop is transport-agnostic — it speaks only the
# `agent.*` event vocabulary through an `emit` callback (D11/D3), so the same loop
# streams in-process (GUI) and over the socket (server.tcl broadcast).
#
# Streaming model (D26): a turn's content is delivered as a sequence of events
# (agent.delta -> agent.message, or agent.error); the op's response is just an
# ack. The loop runs as a coroutine (D10) so it yields while the provider does
# its (async) I/O and never blocks the event loop. The provider posts typed
# messages back to the loop; because a provider may post synchronously, posts are
# always deferred onto the event loop (after 0) so resuming the coroutine is legal
# whether the provider is synchronous (the echo stub) or async (a real network
# provider).
#
# Tool round-trip (D26 slice 4): when the provider asks to run tools
# (`done tool_use`), the loop auto-executes the *read-only* built-ins
# (rio::agent::tools — fs/buffer reads), feeds their results back as a follow-up
# user turn, and re-invokes the provider, repeating until the model finishes.
# Reads happen (they are not proposals); the approval gate is reserved for the
# write/run slice (O4). A step cap bounds the read->think->read loop.
#
# Conversation entries are {role, content} where content is a list of blocks —
# {type text …} / {type tool_use …} / {type tool_result …} — the shape Claude's
# Messages API needs to carry tool exchanges across a turn. history() flattens the
# text blocks back to a readable {role, text} transcript.

namespace eval rio::agent {
	variable conversation {}                       ;# list of {role, content} dicts
	variable turnseq      0                         ;# monotonic turn-id source
	variable maxsteps     8                         ;# max tool round-trips per turn
	variable provider     [namespace current]::echo_provider
}

# Swap the active provider — a command prefix obeying the contract in _run. The
# Claude face (D26: claude-api) registers its provider here.
proc rio::agent::set_provider {cmd} {
	variable provider
	set provider $cmd
}

# Clear the conversation (agent.reset).
proc rio::agent::reset {} {
	variable conversation
	set conversation {}
	return
}

# The conversation so far (agent.history) — a readable {role, text} list. Text is
# the concatenation of an entry's text blocks; pure-machinery turns (tool_use /
# tool_result only) are omitted — the live event stream already surfaced them.
proc rio::agent::history {} {
	variable conversation
	set out {}
	foreach m $conversation {
		if {![_has_text $m]} continue
		lappend out [dict create role [dict get $m role] text [_text_of $m]]
	}
	return $out
}

# Start a turn: record the user message, kick off the orchestration coroutine,
# and return the ack {started, turn}. The turn's content arrives afterward as
# agent.* events on `emit` (D26).
proc rio::agent::send {text emit} {
	variable conversation
	variable turnseq
	set turn [incr turnseq]
	lappend conversation [dict create role user \
		content [list [dict create type text text $text]]]
	coroutine [namespace current]::_turn_$turn \
		[namespace current]::_run $turn $emit
	return [dict create result [dict create started true turn $turn]]
}

# The orchestration coroutine. Each pass invokes the provider, yields to collect
# the typed messages it posts back (mapping each onto an agent.* event), records
# the assistant turn, and — if the model asked for tools — runs them and loops.
#
# Provider contract — `{*}$provider conversation tools post`:
#   tools = the available tool specs (rio::agent::tools::specs); a provider that
#           doesn't do tools ignores it.
#   {*}$post delta <text>                 a chunk of assistant text
#   {*}$post tool  <id> <name> <in> <raw> a requested tool call (in = parsed dict,
#                                         raw = the original input JSON)
#   {*}$post done  ?stop_reason?          the provider step finished; stop_reason
#                                         "tool_use" means "run the tools, continue"
#   {*}$post error <code> <message>       the turn failed (a classified error; D26)
proc rio::agent::_run {turn emit} {
	variable conversation
	variable provider
	variable maxsteps
	set co [info coroutine]
	set toolspecs [rio::agent::tools::specs]
	for {set step 0} {1} {incr step} {
		set acc ""
		set calls {}        ;# tool calls this step: {id name input raw} dicts
		set stop ""
		set failed 0
		{*}$provider $conversation $toolspecs [list [namespace current]::_post $co]
		while {1} {
			set msg [yield]
			switch -- [lindex $msg 0] {
				delta {
					set text [lindex $msg 1]
					append acc $text
					{*}$emit [dict create event agent.delta \
						params [dict create turn $turn text $text]]
				}
				tool {
					lassign $msg _ id name input raw
					lappend calls [dict create id $id name $name input $input raw $raw]
					{*}$emit [dict create event agent.tool \
						params [dict create turn $turn id $id name $name \
							args [_args_str $input]]]
				}
				done  { set stop [lindex $msg 1] ; break }
				error {
					{*}$emit [dict create event agent.error \
						params [dict create turn $turn \
							code [lindex $msg 1] message [lindex $msg 2]]]
					set failed 1 ; break
				}
			}
		}
		if {$failed} return

		# Record the assistant turn (text preamble + any tool_use blocks) so a
		# follow-up request carries Claude's own tool_use, paired with our results.
		set blocks {}
		if {$acc ne ""} { lappend blocks [dict create type text text $acc] }
		foreach c $calls {
			lappend blocks [dict create type tool_use \
				id [dict get $c id] name [dict get $c name] \
				input [dict get $c input] raw [dict get $c raw]]
		}
		lappend conversation [dict create role assistant content $blocks]

		# Model is done (or asked for nothing): close the turn.
		if {$stop ne "tool_use" || ![llength $calls]} {
			{*}$emit [dict create event agent.message \
				params [dict create turn $turn role assistant text $acc]]
			return
		}

		# Runaway guard before the next round-trip (cost + liveness).
		if {$step + 1 >= $maxsteps} {
			{*}$emit [dict create event agent.error \
				params [dict create turn $turn code tool_limit \
					message "Agent stopped after $maxsteps tool steps without finishing"]]
			return
		}

		# Auto-execute the read-only tools and feed results back (reads happen, they
		# are not proposals — D26). Each outcome is surfaced for transparency.
		set results {}
		foreach c $calls {
			set r [rio::agent::tools::run [dict get $c name] [dict get $c input]]
			{*}$emit [dict create event agent.tool_result \
				params [dict create turn $turn id [dict get $c id] \
					name [dict get $c name] ok [dict get $r ok] \
					summary [dict get $r summary]]]
			lappend results [dict create type tool_result \
				tool_use_id [dict get $c id] content [dict get $r content] \
				is_error [expr {[dict get $r ok] ? 0 : 1}]]
		}
		lappend conversation [dict create role user content $results]
	}
}

# A short "k=v k=v" rendering of a tool call's input, for the agent.tool event.
proc rio::agent::_args_str {input} {
	set parts {}
	dict for {k v} $input {
		if {[string length $v] > 60} { set v "[string range $v 0 59]…" }
		lappend parts "$k=$v"
	}
	return [join $parts " "]
}

# --- conversation-entry helpers (a block list, or a legacy {role,text}) -------
proc rio::agent::_blocks {m} {
	if {[dict exists $m content]} { return [dict get $m content] }
	return [list [dict create type text text [dict get $m text]]]
}
proc rio::agent::_text_of {m} {
	set t ""
	foreach b [_blocks $m] {
		if {[dict get $b type] eq "text"} { append t [dict get $b text] }
	}
	return $t
}
proc rio::agent::_has_text {m} {
	foreach b [_blocks $m] {
		if {[dict get $b type] eq "text"} { return 1 }
	}
	return 0
}

# Provider -> loop bridge. Defer the resume onto the event loop so it is always
# legal (a provider may post synchronously, before the coroutine has yielded),
# and guard against a stray post arriving after the coroutine has ended.
proc rio::agent::_post {co args} {
	after 0 [list [namespace current]::_resume $co $args]
}
proc rio::agent::_resume {co msg} {
	if {[llength [info commands $co]]} { $co $msg }
}

# The built-in echo provider — the stub that proves the streaming path with no
# network. It echoes the latest user message back, streamed in word-sized chunks
# on successive event-loop turns (so the async path is genuinely exercised), then
# signals done. The trivial reference implementation of the provider contract;
# the Claude faces (D26) replace it. It does no tools, so it ignores `tools`.
proc rio::agent::echo_provider {conversation tools post} {
	set last [lindex $conversation end]
	set reply "echo: [_text_of $last]"
	_echo_stream $post [regexp -all -inline {\S+\s*} $reply]
}

proc rio::agent::_echo_stream {post chunks} {
	if {![llength $chunks]} {
		{*}$post done
		return
	}
	set chunks [lassign $chunks head]
	{*}$post delta $head
	after 0 [list [namespace current]::_echo_stream $post $chunks]
}

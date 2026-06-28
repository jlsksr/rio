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
# MVP scope (D26): read + propose-edit only; no tool execution yet (O4). The
# built-in provider is an echo stub that exercises the streaming path with no
# network, so the protocol + interface are testable before any Claude code.

namespace eval rio::agent {
	variable conversation {}                       ;# list of {role, text} dicts
	variable turnseq      0                         ;# monotonic turn-id source
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

# The conversation so far (agent.history) — a list of {role, text} dicts.
proc rio::agent::history {} {
	variable conversation
	return $conversation
}

# Start a turn: record the user message, kick off the orchestration coroutine,
# and return the ack {started, turn}. The turn's content arrives afterward as
# agent.* events on `emit` (D26).
proc rio::agent::send {text emit} {
	variable conversation
	variable turnseq
	set turn [incr turnseq]
	lappend conversation [dict create role user text $text]
	coroutine [namespace current]::_turn_$turn \
		[namespace current]::_run $turn $emit
	return [dict create result [dict create started true turn $turn]]
}

# The orchestration coroutine. It calls the provider, then yields to receive the
# typed messages the provider posts back, mapping each onto an agent.* event.
# Ends on `done` (a completed turn) or `error`.
#
# Provider contract — `{*}$provider conversation tools post`:
#   {*}$post delta <text>           a chunk of assistant text
#   {*}$post tool  <id> <name> <in> a proposed tool call (O4; unused in the MVP)
#   {*}$post done                   the turn finished successfully
#   {*}$post error <code> <message> the turn failed (a classified error; D26)
proc rio::agent::_run {turn emit} {
	variable conversation
	variable provider
	set co [info coroutine]
	set acc ""
	{*}$provider $conversation {} [list [namespace current]::_post $co]
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
				# A proposed tool call surfaced for the user to allow (O4). The
				# MVP echo provider never posts this; wired for the next slice.
				{*}$emit [dict create event agent.tool \
					params [dict create turn $turn id [lindex $msg 1] \
						name [lindex $msg 2] input [lindex $msg 3]]]
			}
			done {
				lappend conversation [dict create role assistant text $acc]
				{*}$emit [dict create event agent.message \
					params [dict create turn $turn role assistant text $acc]]
				return
			}
			error {
				{*}$emit [dict create event agent.error \
					params [dict create turn $turn \
						code [lindex $msg 1] message [lindex $msg 2]]]
				return
			}
		}
	}
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
# the Claude faces (D26) replace it.
proc rio::agent::echo_provider {conversation tools post} {
	set last [lindex $conversation end]
	set reply "echo: [dict get $last text]"
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

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
	variable pending                                ;# array: turn -> {coro id} awaiting approval
	variable apply_writes_disk 1                    ;# approved edits also save to disk (D26 s5 default)
	variable auto_accept       0                    ;# skip the approval gate (opt-in)
	variable proposals                              ;# array: turn -> {name,path,original,proposed} awaiting review

	# The named-provider registry (D26/D30). A provider is known by NAME so a
	# frontend can pick one over the channel (agent.provider.set) without ever
	# naming a Tcl command: `echo` is built in; a plugin (claude-api) registers
	# itself when the core loads it. An entry is {provider <cmd> ?key <caps>?},
	# where caps = {set <cmd> clear <cmd> status <cmd>} for a provider that holds a
	# durable credential (the Claude API key; D21).
	variable providers       {}                     ;# name -> entry
	variable active_provider echo                   ;# the registered provider now live
	variable keyed_provider  ""                     ;# name of the key-holding provider (claude)
}

# The write-apply policy (read by rio::agent::tools::apply_write) and its toggles —
# data, so a frontend setting can flip them (the toggle UI is deferred).
proc rio::agent::writes_disk {} { variable apply_writes_disk ; return $apply_writes_disk }
proc rio::agent::set_writes_disk {v} { variable apply_writes_disk ; set apply_writes_disk [expr {$v ? 1 : 0}] }
proc rio::agent::set_auto_accept {v} { variable auto_accept ; set auto_accept [expr {$v ? 1 : 0}] }
proc rio::agent::auto_accept {} { variable auto_accept ; return $auto_accept }

# Swap the active provider directly — a command prefix obeying the contract in
# _run. The low-level hook used by the core's own tests; frontends pick a provider
# by NAME through use_provider (the registry), which also keeps the live name.
proc rio::agent::set_provider {cmd} {
	variable provider
	set provider $cmd
}

# --- named-provider registry (D26/D30) ---------------------------------------
#
# register_provider name cmd ?-key {set .. clear .. status ..}?
#   Record a provider under `name`. `-key` declares the provider holds a durable
#   credential and wires the three commands the agent.key.* ops drive (the claude
#   face uses this for the API key); the agent layer itself stays credential-blind.
proc rio::agent::register_provider {name cmd args} {
	variable providers
	variable keyed_provider
	set entry [dict create provider $cmd]
	foreach {opt val} $args {
		switch -- $opt {
			-key { dict set entry key $val ; set keyed_provider $name }
			default { error "register_provider: unknown option $opt" }
		}
	}
	dict set providers $name $entry
}

# Activate a registered provider by name (agent.provider.set). An unknown name is a
# bad_request — the frontend offered a provider this core doesn't carry.
proc rio::agent::use_provider {name} {
	variable providers
	variable provider
	variable active_provider
	if {![dict exists $providers $name]} {
		rio::error::raise bad_request "unknown agent provider: $name"
	}
	set provider [dict get $providers $name provider]
	set active_provider $name
	return $name
}

proc rio::agent::provider_name  {} { variable active_provider ; return $active_provider }
proc rio::agent::provider_names {} { variable providers ; return [lsort [dict keys $providers]] }

# The key capability of the key-holding provider (claude), or raise if this core
# carries none. key_status answers softly (0) so a frontend can render "no key".
proc rio::agent::_key_caps {} {
	variable providers
	variable keyed_provider
	if {$keyed_provider eq "" || ![dict exists $providers $keyed_provider key]} {
		rio::error::raise bad_request "this core has no key-based agent provider"
	}
	return [dict get $providers $keyed_provider key]
}
proc rio::agent::key_set {key} { {*}[dict get [_key_caps] set] $key ; return }
proc rio::agent::key_clear {}   { {*}[dict get [_key_caps] clear] ; return }
proc rio::agent::key_status {} {
	variable providers
	variable keyed_provider
	if {$keyed_provider eq "" || ![dict exists $providers $keyed_provider key]} { return 0 }
	return [{*}[dict get $providers $keyed_provider key status]]
}

# Clear the conversation (agent.reset). Also abort any turn suspended awaiting an
# approval — its coroutine would otherwise linger waiting for a decision that the
# cleared conversation will never produce.
proc rio::agent::reset {} {
	variable conversation
	variable pending
	variable proposals
	set conversation {}
	foreach turn [array names pending] {
		lassign $pending($turn) co id
		catch {rename $co {}}
	}
	array unset pending
	array unset proposals
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

# Make the conversation safe to extend with a fresh turn. A turn can be abandoned
# with unfinished tool business — suspended at the approval gate (the user typed a
# new message instead of deciding) or stopped at the step cap — leaving an
# assistant turn whose tool_use blocks have no tool_result. Claude rejects that on
# the next request ("tool_use ids ... without tool_result"), so before a new turn
# we (a) abort any turn suspended awaiting approval — its coroutine must never
# resume into the new turn's conversation — and (b) return an "interrupted"
# tool_result for each dangling tool_use, which `send` folds into the new user
# message so the assistant tool_use stays immediately followed by its tool_result
# (one user turn carrying both the results and the new text — roles still alternate).
proc rio::agent::_seal_dangling {} {
	variable conversation
	variable pending
	variable proposals
	foreach turn [array names pending] {
		lassign $pending($turn) co id
		catch {rename $co {}}
	}
	array unset pending
	array unset proposals
	set last [lindex $conversation end]
	set results {}
	if {[llength $last] && [dict get $last role] eq "assistant"} {
		foreach b [_blocks $last] {
			if {[dict get $b type] eq "tool_use"} {
				lappend results [dict create type tool_result \
					tool_use_id [dict get $b id] \
					content "This tool call was interrupted before it completed." is_error 1]
			}
		}
	}
	return $results
}

# Start a turn: record the user message, kick off the orchestration coroutine,
# and return the ack {started, turn}. The turn's content arrives afterward as
# agent.* events on `emit` (D26).
proc rio::agent::send {text emit} {
	variable conversation
	variable turnseq
	set seal [_seal_dangling]
	set turn [incr turnseq]
	lappend conversation [dict create role user \
		content [concat $seal [list [dict create type text text $text]]]]
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
					# Announce a read call now (it auto-runs); a write call is announced
					# in phase 2 as agent.propose, carrying the diff for review.
					if {![rio::agent::tools::is_write $name]} {
						{*}$emit [dict create event agent.tool \
							params [dict create turn $turn id $id name $name \
								args [_args_str $input]]]
					}
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

		# Run each tool and feed its result back. Reads auto-execute (they are not
		# proposals); writes go through the approval gate (_do_write) — proposed,
		# reviewed, then applied or rejected (D26 s5). Each outcome is surfaced.
		set results {}
		foreach c $calls {
			set name [dict get $c name]
			set id   [dict get $c id]
			if {[rio::agent::tools::is_write $name]} {
				set r [_do_write $turn $id $name [dict get $c input] $emit $co]
			} else {
				set r [rio::agent::tools::run $name [dict get $c input]]
				{*}$emit [dict create event agent.tool_result \
					params [dict create turn $turn id $id name $name \
						ok [dict get $r ok] summary [dict get $r summary]]]
			}
			lappend results [dict create type tool_result \
				tool_use_id $id content [dict get $r content] \
				is_error [expr {[dict get $r ok] ? 0 : 1}]]
		}
		lappend conversation [dict create role user content $results]
	}
}

# Handle one WRITE tool call: prepare a reviewable proposal, surface it
# (agent.propose, with the diff), then either auto-accept or yield until an
# agent.approve resumes us with the user's decision. On approval the edit applies
# (its buffer.changed events forwarded so an open view updates); a rejection feeds
# Claude a plain "rejected" tool_result. Returns the {ok, content, summary} the
# loop turns into the tool_result block. (D26 slice 5.)
proc rio::agent::_do_write {turn id name input emit co} {
	variable pending
	variable auto_accept
	variable proposals
	set prep [rio::agent::tools::prepare_write $name $input]
	if {[dict get $prep ok] == 0} {
		{*}$emit [dict create event agent.tool_result \
			params [dict create turn $turn id $id name $name ok 0 \
				summary [dict get $prep summary]]]
		return $prep
	}
	{*}$emit [dict create event agent.propose \
		params [dict create turn $turn id $id name $name \
			path [dict get $prep path] diff [dict get $prep diff]]]
	if {$auto_accept} {
		set decision approve
	} else {
		set pending($turn) [list $co $id]
		set proposals($turn) [dict create name $name path [dict get $prep path] \
			original [dict get $prep original] proposed [dict get $prep proposed]]
		set decision [yield]
		unset -nocomplain pending($turn)
		unset -nocomplain proposals($turn)
	}
	if {$decision ne "approve"} {
		{*}$emit [dict create event agent.tool_result \
			params [dict create turn $turn id $id name $name ok 0 summary "rejected by user"]]
		return [dict create ok 0 content "The user rejected this edit." summary "rejected by user"]
	}
	set r [rio::agent::tools::apply_write [dict get $prep plan]]
	if {[dict exists $r events]} {
		foreach ev [dict get $r events] { {*}$emit $ev }
	}
	{*}$emit [dict create event agent.tool_result \
		params [dict create turn $turn id $id name $name \
			ok [dict get $r ok] summary [dict get $r summary]]]
	return $r
}

# Resolve a pending approval: resume the suspended turn's coroutine with the user's
# decision ("approve" | "reject"). Driven by the agent.approve op (D26 s5).
proc rio::agent::approve {turn decision} {
	variable pending
	if {![info exists pending($turn)]} {
		rio::error::raise bad_request "no edit is awaiting approval for turn $turn"
	}
	lassign $pending($turn) co id
	after 0 [list [namespace current]::_resume $co $decision]
	return $id
}

# A pending proposal's full texts (agent.proposal, D28): the original file content
# and the proposed new content for a turn whose write is awaiting the user's
# decision. The compare/diff view pulls this on demand — only when opened — so the
# agent.propose event itself stays lean. Raises if nothing is pending for the turn.
proc rio::agent::proposal {turn} {
	variable proposals
	if {![info exists proposals($turn)]} {
		rio::error::raise bad_request "no proposal is awaiting review for turn $turn"
	}
	return $proposals($turn)
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

# The built-in, always-available provider. A keyed provider (claude) registers
# itself from its plugin when the core loads it (server.tcl).
rio::agent::register_provider echo ::rio::agent::echo_provider

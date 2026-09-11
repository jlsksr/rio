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
# write/run slice (O4). The loop runs until the model is done: a job worth doing
# takes the steps it takes, and the bound is the user's Stop, not a number the core
# guessed in advance (agent.stop, D104).
#
# Modes (D101): the loop runs in `build` (the normal working set) or `plan`, where the
# tool list handed to the provider holds only the reads and `present_plan` and the prompt
# gains a planning layer. Because BOTH the tool list and the system prompt are composed
# here, planning behaves the same whatever provider is live — a provider cannot opt out of
# a mode it never learns about. Approving a presented plan flips the mode back to `build`
# inside the same turn, which is why the loop recomputes tools and prompt every step.
#
# Conversation entries are {role, content} where content is a list of blocks —
# {type text …} / {type tool_use …} / {type tool_result …} — the shape Claude's
# Messages API needs to carry tool exchanges across a turn. history() flattens the
# text blocks back to a readable {role, text} transcript.

namespace eval rio::agent {
	variable conversation {}                       ;# list of {role, content} dicts
	variable turnseq      0                         ;# monotonic turn-id source
	variable provider     [namespace current]::echo_provider
	variable live                                   ;# array: turn -> coro of a turn in flight (D104)
	variable pending                                ;# array: turn -> {coro id} awaiting approval
	variable apply_writes_disk 1                    ;# approved edits also save to disk (D26 s5 default)
	variable auto_accept       0                    ;# skip the approval gate (opt-in; EDITS only, D83)
	variable mode              build                ;# build | plan — which tools exist (D101)
	variable proposals                              ;# array: turn -> {name,path,original,proposed} awaiting review
	variable running                                ;# array: turn -> {coro token} a run_command in flight (D83)

	# The named-provider registry (D26/D30). A provider is known by NAME so a
	# frontend can pick one over the channel (agent.provider.set) without ever
	# naming a Tcl command: `echo` is built in; a plugin (claude-api, openai)
	# registers itself when the core loads it. An entry is
	# {provider <cmd> label <text> signup <text> ?key <caps>?}, where caps =
	# {set <cmd> clear <cmd> status <cmd>} for a provider that holds a durable
	# credential (an API key; D21). Key state is PER PROVIDER — several keyed
	# providers coexist (claude AND openai), each with its own store — so there is
	# no single key-holder slot; agent.key.* names its target.
	variable providers       {}                     ;# name -> entry
	variable active_provider echo                   ;# the registered provider now live
}

# The write-apply policy (read by rio::agent::tools::apply_write) and its toggles —
# data, so a frontend setting can flip them (the toggle UI is deferred).
proc rio::agent::writes_disk {} { variable apply_writes_disk ; return $apply_writes_disk }
proc rio::agent::set_writes_disk {v} { variable apply_writes_disk ; set apply_writes_disk [expr {$v ? 1 : 0}] }
proc rio::agent::set_auto_accept {v} { variable auto_accept ; set auto_accept [expr {$v ? 1 : 0}] }
proc rio::agent::auto_accept {} { variable auto_accept ; return $auto_accept }

# The agent's mode (D101). `plan` withholds every tool that changes anything — the model
# can read and then present_plan, nothing else — and adds the plan prompt layer; `build`
# is the normal working set. It lives here, in the core, so the restriction holds for every
# provider and every frontend attached to this core (D3/D30). An unknown value is a
# bad_request: a mode is a state, not a hint.
proc rio::agent::set_mode {m} {
	variable mode
	if {$m ni {build plan}} {
		rio::error::raise bad_request "unknown agent mode: $m"
	}
	set mode $m
	return $mode
}
proc rio::agent::mode {} { variable mode ; return $mode }

# Swap the active provider directly — a command prefix obeying the contract in
# _run. The low-level hook used by the core's own tests; frontends pick a provider
# by NAME through use_provider (the registry), which also keeps the live name.
proc rio::agent::set_provider {cmd} {
	variable provider
	set provider $cmd
}

# --- named-provider registry (D26/D30) ---------------------------------------
#
# register_provider name cmd ?-label <text>? ?-signup <text>? ?-key {set .. clear .. status ..}?
#   Record a provider under `name`. `-label` is its display name (a frontend's
#   menus/badge; defaults to the name) and `-signup` a where-to-get-a-key hint —
#   both DATA the provider owns, so the GUI's picker and key dialog are generic
#   (they render whatever a provider declares; an installed provider ships its own,
#   milestone B). `-key` declares the provider holds a durable credential and wires
#   the three commands the agent.key.* ops drive; the agent layer stays
#   credential-blind and each keyed provider keeps its own store.
proc rio::agent::register_provider {name cmd args} {
	variable providers
	set entry [dict create provider $cmd label $name signup ""]
	foreach {opt val} $args {
		switch -- $opt {
			-key    { dict set entry key $val }
			-label  { dict set entry label $val }
			-signup { dict set entry signup $val }
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

# A rendering of every registered provider for a frontend's picker + key UI
# (agent.providers): {name, label, keyed (0/1), key_set (0/1), signup}. Sorted by
# name for a stable menu order. All leaves are strings (the wire's flat-object
# encoder applies).
proc rio::agent::providers_info {} {
	variable providers
	set out {}
	foreach name [lsort [dict keys $providers]] {
		set e [dict get $providers $name]
		set keyed [dict exists $e key]
		lappend out [dict create \
			name    $name \
			label   [dict get $e label] \
			keyed   [expr {$keyed ? 1 : 0}] \
			key_set [expr {$keyed ? [key_status $name] : 0}] \
			signup  [dict get $e signup]]
	}
	return $out
}

# The provider a key op targets: the given name, or the active provider when none
# is named (the common case — configure the key for the provider you just picked).
proc rio::agent::_key_target {name} {
	variable active_provider
	return [expr {$name eq "" ? $active_provider : $name}]
}

# The key capability of a named provider, or raise if it has none. (A frontend
# should only offer the key dialog for a provider whose agent.providers entry has
# keyed=1, so this raises only on a misuse.) key_status answers softly (0) so a
# frontend can render "no key" for any provider, keyed or not.
proc rio::agent::_key_caps {name} {
	variable providers
	if {![dict exists $providers $name] || ![dict exists $providers $name key]} {
		rio::error::raise bad_request "agent provider '$name' has no key store"
	}
	return [dict get $providers $name key]
}
proc rio::agent::key_set {key {name ""}} {
	{*}[dict get [_key_caps [_key_target $name]] set] $key ; return
}
proc rio::agent::key_clear {{name ""}} {
	{*}[dict get [_key_caps [_key_target $name]] clear] ; return
}
proc rio::agent::key_status {{name ""}} {
	variable providers
	set name [_key_target $name]
	if {![dict exists $providers $name] || ![dict exists $providers $name key]} { return 0 }
	return [{*}[dict get $providers $name key status]]
}

# Clear the conversation (agent.reset). Also abort any turn suspended awaiting an
# approval — its coroutine would otherwise linger waiting for a decision that the
# cleared conversation will never produce.
proc rio::agent::reset {} {
	variable conversation
	_abort_all
	set conversation {}
	return
}

# Abort ONE turn: cancel a command it has running, delete its coroutine, forget its
# bookkeeping. Returns 1 only if a turn was actually live — a registration whose coroutine
# has already finished is pruned, not counted, so Stop cannot report a phantom (D104).
# The three abort paths — reset, a new message, and Stop — all go through here, because
# "forget this turn" means the same thing in each.
proc rio::agent::_abort {t} {
	variable live
	variable pending
	variable proposals
	variable running
	set was 0
	if {[info exists running($t)]} {
		lassign $running($t) rco token
		catch {rio::exec::cancel $token}
	}
	if {[info exists live($t)] && [llength [info commands $live($t)]]} {
		catch {rename $live($t) {}}
		set was 1
	}
	unset -nocomplain live($t) pending($t) proposals($t) running($t)
	return $was
}

# Abort every turn the core is carrying. Before D104 this reached only turns parked at the
# approval gate or running a command; a turn waiting on the PROVIDER was left alone, and
# would wake up later to stream into a conversation that had been cleared or replaced. The
# live registry makes that reachable, and turns now run long enough for it to matter.
proc rio::agent::_abort_all {} {
	variable live
	variable pending
	variable running
	set n 0
	foreach t [lsort -unique [concat [array names live] [array names pending] \
			[array names running]]] {
		incr n [_abort $t]
	}
	return $n
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
	_abort_all
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
	variable live
	set turn [incr turnseq]
	lappend conversation [dict create role user \
		content [concat $seal [list [dict create type text text $text]]]]
	# Registered BEFORE the coroutine runs: `coroutine` executes the body up to its first
	# yield, and a turn that finishes without yielding would otherwise clear an entry that
	# had not been made yet.
	set co [namespace current]::_turn_$turn
	set live($turn) $co
	coroutine $co [namespace current]::_run_guarded $turn $emit
	return [dict create result [dict create started true turn $turn]]
}

# _run under a registration guard: the turn is "live" from the moment it starts until it
# returns, however it returns (D104). Stopping a turn deletes its coroutine, so this is not
# the only thing that clears the entry — `stop` unsets it too, and both are idempotent.
proc rio::agent::_run_guarded {turn emit} {
	variable live
	try {
		_run $turn $emit
	} finally {
		unset -nocomplain live($turn)
	}
}

# Stop a turn in flight (agent.stop, D104) — the frontend's Stop button, and the only way
# out of a long turn now that there is no step cap. `turn` omitted stops every live turn.
#
# Mechanically it is the abort the reset/seal paths already use: cancel a command if one is
# running, delete the coroutine. Deleting it is enough to stop the provider from driving the
# turn any further — _resume drops a post whose coroutine is gone — though a request already
# on the wire is not recalled: it finishes into the void and is still billed. The user asked
# for the work to stop, and it stops; we do not pretend the tokens come back.
#
# Returns the turns actually stopped (a turn that had already finished is not an error —
# the click raced the last event, which is not the user's problem).
proc rio::agent::stop {{turn ""}} {
	variable live
	set turns [expr {$turn eq "" ? [array names live] : [list $turn]}]
	set stopped {}
	foreach t $turns {
		if {[_abort $t]} { lappend stopped $t }
	}
	if {[llength $stopped]} { _close_interrupted }
	return $stopped
}

# Leave the conversation extendable after a turn was cut off mid-flight. A turn killed while
# the provider was still working has recorded nothing — the assistant entry is written only
# once the provider says `done` — so the last entry is the user's message, and the next
# `send` would append a second user entry in a row, which the Messages API rejects. A short
# assistant note restores the alternation and is honest about what happened; anything the
# model had already streamed is lost with its coroutine, which is why the note says only
# that it was stopped. A turn killed at the approval gate needs nothing here: its assistant
# turn IS recorded, and _seal_dangling answers its dangling tool_use on the next send.
proc rio::agent::_close_interrupted {} {
	variable conversation
	set last [lindex $conversation end]
	if {![llength $last] || [dict get $last role] ne "user"} return
	lappend conversation [dict create role assistant \
		content [list [dict create type text text "(Stopped by the user.)"]]]
}

# The orchestration coroutine. Each pass invokes the provider, yields to collect
# the typed messages it posts back (mapping each onto an agent.* event), records
# the assistant turn, and — if the model asked for tools — runs them and loops.
#
# Provider contract — `{*}$provider conversation tools system post`:
#   tools  = the available tool specs (rio::agent::tools::specs); a provider that
#            doesn't do tools ignores it.
#   system = the core-composed system prompt (rio::agent::prompt::compose, D34/D70/
#            D79) — base + the user's system layer + the ACTIVE provider's own layer +
#            the project layer, joined into one provider-agnostic string the provider
#            sends however its API spells "system prompt"; a provider without one (echo)
#            ignores it. The provider never sees the layers — only the composed string.
#   {*}$post delta <text>                 a chunk of assistant text
#   {*}$post tool  <id> <name> <in> <raw> a requested tool call (in = parsed dict,
#                                         raw = the original input JSON)
#   {*}$post done  ?stop_reason?          the provider step finished; stop_reason
#                                         "tool_use" means "run the tools, continue"
#   {*}$post error <code> <message>       the turn failed (a classified error; D26)
proc rio::agent::_run {turn emit} {
	variable conversation
	variable provider
	set co [info coroutine]
	while {1} {
		# Recomputed EVERY step, not once per turn: approving a plan flips the mode
		# mid-turn (D101), and the model has to see the tools it just earned on the very
		# next call — otherwise it goes on planning with a stale list. The system prompt
		# follows for the same reason (the plan layer drops away with the mode).
		set toolspecs [rio::agent::tools::specs [mode]]
		set system [rio::agent::prompt::compose [rio::agent::provider_name] [mode]]
		set acc ""
		set calls {}        ;# tool calls this step: {id name input raw} dicts
		set stop ""
		set failed 0
		{*}$provider $conversation $toolspecs $system [list [namespace current]::_post $co]
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
					# Announce a read call now (it auto-runs); a gated call (write or
					# run_command) is announced in phase 2 as agent.propose, carrying the
					# diff / the command for review.
					if {![rio::agent::tools::is_gated $name]} {
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

		# Run each tool and feed its result back. Reads auto-execute (they are not
		# proposals); writes go through the approval gate (_do_write) — proposed,
		# reviewed, then applied or rejected (D26 s5). Each outcome is surfaced.
		set results {}
		foreach c $calls {
			set name [dict get $c name]
			set id   [dict get $c id]
			switch -- [rio::agent::tools::kind_of $name] {
				write { set r [_do_write $turn $id $name [dict get $c input] $emit $co] }
				exec  { set r [_do_exec  $turn $id $name [dict get $c input] $emit $co] }
				plan  { set r [_do_plan  $turn $id $name [dict get $c input] $emit $co] }
				default {
					set r [rio::agent::tools::run $name [dict get $c input]]
					{*}$emit [dict create event agent.tool_result \
						params [dict create turn $turn id $id name $name \
							ok [dict get $r ok] summary [dict get $r summary]]]
				}
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

# Handle one run_command call (D83): prepare a reviewable command, surface it
# (agent.propose, kind command), and — unless a human-authored allow-list rule already
# covers this argv (D84 standing approval) — yield until an agent.approve resumes us
# with the user's decision. The edits-only auto_accept toggle never applies here:
# running arbitrary argv is the most dangerous tool, so absent an explicit allow rule a
# human always confirms the exact command. On approval (or an allow-list match) the
# command runs ASYNCHRONOUSLY via rio::exec::start (the core stays responsive while
# it runs) and we yield again until its completion callback resumes us; the result
# becomes the tool_result. On rejection the model gets a plain "rejected". The
# in-flight command is registered in `running` so reset/_seal_dangling can kill it.
proc rio::agent::_do_exec {turn id name input emit co} {
	variable pending
	variable running
	set prep [rio::agent::tools::prepare_exec $input]
	if {[dict get $prep ok] == 0} {
		{*}$emit [dict create event agent.tool_result \
			params [dict create turn $turn id $id name $name ok 0 \
				summary [dict get $prep summary]]]
		return $prep
	}
	# Standing approval (D84): a command whose argv is covered by a human-authored
	# allow-list rule runs WITHOUT the bar. The `auto` flag rides the propose event so
	# the frontend can show what auto-ran (no bar, work continues). This skips only the
	# human confirmation — prepare_exec above already applied every other guard.
	set auto [rio::agent::allow::matches [dict get $prep command]]
	{*}$emit [dict create event agent.propose \
		params [dict create turn $turn id $id name $name kind command \
			command [dict get $prep command] cwd [dict get $prep cwddisp] \
			display [dict get $prep display] auto $auto]]
	if {!$auto} {
		set pending($turn) [list $co $id]
		set decision [yield]
		unset -nocomplain pending($turn)
		if {$decision ne "approve"} {
			{*}$emit [dict create event agent.tool_result \
				params [dict create turn $turn id $id name $name ok 0 summary "rejected by user"]]
			return [dict create ok 0 content "The user rejected running this command." summary "rejected by user"]
		}
	}
	set token [rio::exec::start [dict get $prep command] [dict get $prep cwd] "" \
		[expr {[dict get $prep timeout] * 1000}] \
		[list [namespace current]::_exec_done $co]]
	set running($turn) [list $co $token]
	set result [yield]
	unset -nocomplain running($turn)
	set r [rio::agent::tools::format_exec [dict get $prep command] $result]
	{*}$emit [dict create event agent.tool_result \
		params [dict create turn $turn id $id name $name \
			ok [dict get $r ok] summary [dict get $r summary]]]
	return $r
}

# Handle one present_plan call (D101): file the plan, surface it (agent.propose, kind
# plan, carrying the Markdown itself — unlike a write's full texts there is only one
# document and the frontend needs all of it to render anything, so there is nothing for a
# pull op to keep lean), and yield until the user decides. ALWAYS gated: `auto_accept` is
# edits-only (D83), and a plan whose whole purpose is a human's judgement is the last
# thing to auto-approve. Approval flips the mode to `build` and tells the model to carry
# the plan out — the loop's per-step spec recompute then hands it the tools to do it with,
# each edit still stopped by the ordinary gate. Rejection leaves the mode alone: the user
# is still planning, and the model should plan again.
#
# The plan is re-read at approval (D102). Its file in the project IS the plan, so the user
# can open it and change it before approving, and what they approved — not what the model
# wrote — is what comes back in the tool_result. Unchanged, the short result stands: there
# is no point echoing the model's own words at it.
proc rio::agent::_do_plan {turn id name input emit co} {
	variable pending
	set prep [rio::agent::tools::prepare_plan $input]
	if {[dict get $prep ok] == 0} {
		{*}$emit [dict create event agent.tool_result \
			params [dict create turn $turn id $id name $name ok 0 \
				summary [dict get $prep summary]]]
		return $prep
	}
	{*}$emit [dict create event agent.propose \
		params [dict create turn $turn id $id name $name kind plan \
			title [dict get $prep title] plan [dict get $prep markdown] \
			path [dict get $prep path]]]
	set pending($turn) [list $co $id]
	set decision [yield]
	unset -nocomplain pending($turn)
	if {$decision ne "approve"} {
		{*}$emit [dict create event agent.tool_result \
			params [dict create turn $turn id $id name $name ok 0 summary "rejected by user"]]
		return [dict create ok 0 \
			content "The user rejected this plan. Do not start work — ask what they want changed about it, or present a revised plan." \
			summary "rejected by user"]
	}
	# Leaving plan mode is news only if we were in it (D103: a plan can be presented from
	# any mode). Announcing a flip that did not happen would relabel the frontend's mode
	# control for nothing.
	if {[mode] eq "plan"} {
		set_mode build
		{*}$emit [dict create event agent.mode params [dict create mode build]]
		set content "The user approved this plan. Plan mode is off and the editing tools are available again — carry the plan out now, step by step; each edit and command still waits for the user's approval."
	} else {
		set content "The user approved this plan. Carry it out now, step by step; each edit and command still waits for the user's approval."
	}
	set summary "plan approved"
	set now [rio::agent::tools::read_plan [dict get $prep path]]
	if {$now ne "" && [string trimright $now] ne [string trimright [dict get $prep markdown]]} {
		append content "\n\nThe user EDITED the plan before approving it. What they approved is the text below, not what you wrote — follow this version:\n\n$now"
		set summary "plan approved (edited)"
	}
	{*}$emit [dict create event agent.tool_result \
		params [dict create turn $turn id $id name $name ok 1 summary $summary]]
	return [dict create ok 1 content $content summary $summary]
}

# rio::exec::start's completion bridge: resume the suspended turn with the capture.
# Deferred onto the event loop like _post, so resuming is always legal.
proc rio::agent::_exec_done {co result} {
	after 0 [list [namespace current]::_resume $co $result]
}

# Resolve a pending approval: resume the suspended turn's coroutine with the user's
# decision ("approve" | "reject"). Driven by the agent.approve op (D26 s5). Serves a
# proposed edit, a proposed command and a presented plan alike — all park in `pending`.
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
# the Claude faces (D26) replace it. It does no tools and has no system prompt, so
# it ignores `tools` and `system`.
proc rio::agent::echo_provider {conversation tools system post} {
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

# The built-in, always-available provider. Keyed providers (claude, openai)
# register themselves from their plugins when the core loads them (server.tcl).
rio::agent::register_provider echo ::rio::agent::echo_provider -label Echo

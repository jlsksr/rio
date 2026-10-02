# rio-core — the agent orchestration loop (D20, D26).
#
# The core owns the conversation and the loop. A provider (D8) only talks to
# its model. The loop speaks `agent.*` events through an `emit` callback, so
# it does not know the transport.
#
#   agent.send ──► _run (a coroutine, one per turn)
#                    │  provider conversation tools system post
#                    ▼
#                  provider ──post──► delta, thinking, tool, done, error
#                    │
#                    ├─ done, no tools ──► agent.message, turn ends
#                    └─ done tool_use  ──► run the tools, append the results,
#                                          call the provider again
#
# - The op's response is an ack; the content arrives as events (D26).
# - A coroutine (D10), so the core never blocks on the provider's I/O. A post
#   is deferred with `after 0`: a provider may post before the loop yields.
# - Reads run at once. A write, a command and a plan wait for the user.
# - No step cap. The user's Stop ends a long turn (agent.stop, D104).
# - Modes (D101): `build`, or `plan`, where the tool list holds only the reads
#   and `present_plan`. Tools and prompt are composed here, so a mode holds
#   for every provider.
#
# A conversation entry is {role content}. `content` is a list of blocks:
# {type text …}, {type tool_use …}, {type tool_result …}.

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
	variable scopes                                 ;# array: turn -> {buffer start end original} a selection-scoped turn (D113)

	# The provider registry (D26/D30). A frontend picks a provider by name
	# (agent.provider.set), never by Tcl command. `echo` is built in; an
	# extension registers itself when the core loads it. An entry:
	#   {provider <cmd> label <text> signup <text> ?key <caps>? ?options <caps>?
	#    ?profiles <caps>?}
	# Each keyed provider has its own key store (D21).
	variable providers       {}                     ;# name -> entry
	variable active_provider echo                   ;# the registered provider now live
}

# The write-apply policy and its toggles (read by rio::agent::tools::apply_write).
proc rio::agent::writes_disk {} { variable apply_writes_disk ; return $apply_writes_disk }
proc rio::agent::set_writes_disk {v} { variable apply_writes_disk ; set apply_writes_disk [expr {$v ? 1 : 0}] }
proc rio::agent::set_auto_accept {v} { variable auto_accept ; set auto_accept [expr {$v ? 1 : 0}] }
proc rio::agent::auto_accept {} { variable auto_accept ; return $auto_accept }

# The agent's mode (D101): `build`, or `plan`, which withholds every tool that
# changes anything and adds the plan prompt layer. An unknown value is a
# bad_request.
proc rio::agent::set_mode {m} {
	variable mode
	if {$m ni {build plan}} {
		rio::error::raise bad_request "unknown agent mode: $m"
	}
	set mode $m
	return $mode
}
proc rio::agent::mode {} { variable mode ; return $mode }

# Set the active provider command directly (contract: see _run). For the
# core's tests; a frontend uses use_provider.
proc rio::agent::set_provider {cmd} {
	variable provider
	set provider $cmd
}

# --- named-provider registry (D26/D30) ---------------------------------------
#
# register_provider name cmd ?-label <text>? ?-signup <text>? ?-key {set .. clear .. status ..}?
#                             ?-options {list .. set .. ?refresh ..? ?file ..?}?
#                             ?-profiles {list .. switch .. add .. remove .. rename ..}?
#   Record a provider under `name`.
#     -label     display name; defaults to the name
#     -signup    a hint where to get a key
#     -key       it stores a credential; the commands behind agent.key.*
#     -options   it has runtime choices, e.g. its model (D106); agent.option.*
#     -profiles  it keeps several named configurations (D131); agent.profile*
#   The last three are commands, not data: only the provider can answer them.
proc rio::agent::register_provider {name cmd args} {
	variable providers
	set entry [dict create provider $cmd label $name signup ""]
	foreach {opt val} $args {
		switch -- $opt {
			-key      { dict set entry key $val }
			-options  { dict set entry options $val }
			-profiles { dict set entry profiles $val }
			-label    { dict set entry label $val }
			-signup   { dict set entry signup $val }
			default   { error "register_provider: unknown option $opt" }
		}
	}
	dict set providers $name $entry
}

# Activate a registered provider by name (agent.provider.set).
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

# Does this core carry a provider by that name? "Unknown provider" and
# "provider without options" are different answers (D106).
proc rio::agent::provider_known {name} {
	variable providers
	return [dict exists $providers $name]
}

# Every registered provider, for a frontend's picker and key UI
# (agent.providers), sorted by name:
#   {name label keyed key_set signup options profiles}
# `options` and `profiles` are 0/1: does it declare any? That saves a round
# trip per provider.
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
			signup   [dict get $e signup] \
			options  [expr {[dict exists $e options] ? 1 : 0}] \
			profiles [expr {[dict exists $e profiles] ? 1 : 0}]]
	}
	return $out
}

# The provider a key or option op targets: the named one, else the active one.
proc rio::agent::_key_target {name} {
	variable active_provider
	return [expr {$name eq "" ? $active_provider : $name}]
}

# The key capability of a named provider, or raise. key_status answers 0
# instead, so a frontend can ask about any provider.
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

# --- a provider's runtime options (D106) -------------------------------------
#
# Which model, how much effort: a provider's own choices. The core routes them
# and never learns what one means, so a new option needs no core or GUI change.
#
# A descriptor is a dict; a provider must give `name` and `value`, and
# _option_norm fills in the rest.

# The options capability of a named provider, or raise.
proc rio::agent::_options_caps {name} {
	variable providers
	if {![dict exists $providers $name]} {
		rio::error::raise bad_request "unknown agent provider: $name"
	}
	if {![dict exists $providers $name options]} {
		rio::error::raise bad_request "agent provider '$name' has no options"
	}
	return [dict get $providers $name options]
}

# One descriptor with every key present:
#
#   name, label, hint, value
#   choices  a list of {value label}; a bare value is its own label
#   free     1 = a value outside `choices` is allowed
#   refresh  1 = the choices can be re-fetched (options_refresh)
#   kind     choice (default) | text | number: which control to draw. The
#            provider, not the core, decides what is valid.
#   group    a section heading, "" for none. Sections and members keep
#            declaration order.
#   file     1 = the value names a file the user may edit. The provider
#            resolves the path (agent.option.file, D131).
#   quick    1 (default) = a frontend may also offer it in a quick control;
#            0 = settings only.
#
# A frontend that meets an unknown `kind` draws `choice` if there are choices,
# else `text`.
proc rio::agent::_option_norm {o} {
	set out [dict create name "" label "" hint "" value "" free 0 refresh 0 file 0 \
		choices {} kind choice group "" quick 1]
	set out [dict merge $out $o]
	if {[dict get $out label] eq ""} { dict set out label [dict get $out name] }
	if {[dict get $out kind] eq ""} { dict set out kind choice }
	set cs {}
	foreach c [dict get $out choices] {
		if {[llength $c] == 1} {
			lappend cs [dict create value $c label $c]
		} else {
			set v [dict get $c value]
			lappend cs [dict create value $v \
				label [expr {[dict exists $c label] ? [dict get $c label] : $v}]]
		}
	}
	dict set out choices $cs
	dict set out free    [expr {[dict get $out free]    ? 1 : 0}]
	dict set out refresh [expr {[dict get $out refresh] ? 1 : 0}]
	dict set out file    [expr {[dict get $out file]    ? 1 : 0}]
	dict set out quick   [expr {[dict get $out quick]   ? 1 : 0}]
	return $out
}

# Every option a provider declares, normalized. {} for a provider without any.
proc rio::agent::options {{name ""}} {
	variable providers
	set name [_key_target $name]
	if {![dict exists $providers $name] || ![dict exists $providers $name options]} { return {} }
	set out {}
	foreach o [{*}[dict get $providers $name options list]] { lappend out [_option_norm $o] }
	return $out
}

# The same as a flat {name value …} dict, for agent.status.
proc rio::agent::options_summary {{name ""}} {
	set out [dict create]
	foreach o [options $name] { dict set out [dict get $o name] [dict get $o value] }
	return $out
}

# The descriptor of a provider's option, or raise. The core checks that the
# option exists; whether a value is valid is the provider's question.
proc rio::agent::_option_find {name option} {
	foreach o [options $name] {
		if {[dict get $o name] eq $option} { return $o }
	}
	rio::error::raise bad_request "agent provider '$name' has no option '$option'"
}

# Choose a value (agent.option.set). Returns what the provider accepted,
# which may be a canonical form. The provider raises on a refused value.
proc rio::agent::option_set {option value {name ""}} {
	set name [_key_target $name]
	set caps [_options_caps $name]
	_option_find $name $option
	{*}[dict get $caps set] $option $value
	return [dict get [_option_find $name $option] value]
}

# Re-fetch an option's choices, e.g. from a models endpoint (D106).
# Asynchronous: the provider announces `agent.options` when the answer lands.
proc rio::agent::options_refresh {option emit {name ""}} {
	set name [_key_target $name]
	set caps [_options_caps $name]
	set o [_option_find $name $option]
	if {![dict get $o refresh] || ![dict exists $caps refresh]} {
		rio::error::raise bad_request "option '$option' cannot be refreshed"
	}
	{*}[dict get $caps refresh] $option [list rio::agent::announce_options $name $emit]
	return 1
}

# Resolve and create the file an option's value names (agent.option.file,
# D131), so a frontend can open it. The provider does both: it knows where the
# file lives. Returns {path created}.
proc rio::agent::option_file {option {name ""}} {
	set name [_key_target $name]
	set caps [_options_caps $name]
	set o [_option_find $name $option]
	if {![dict get $o file] || ![dict exists $caps file]} {
		rio::error::raise bad_request "option '$option' names no file"
	}
	set r [{*}[dict get $caps file] $option]
	if {![dict exists $r path] || [dict get $r path] eq ""} {
		rio::error::raise io_error "cannot resolve the file for option '$option'"
	}
	return $r
}

# --- a provider's profiles (D131) --------------------------------------------
#
# Several named configurations, one active: hosted ChatGPT here, a local
# llama-server there. The core knows only that a profile has a name and one is
# active. What it holds is the provider's business.

# The profiles capability of a named provider, or raise.
proc rio::agent::_profiles_caps {name} {
	variable providers
	if {![dict exists $providers $name]} {
		rio::error::raise bad_request "unknown agent provider: $name"
	}
	if {![dict exists $providers $name profiles]} {
		rio::error::raise bad_request "agent provider '$name' has no profiles"
	}
	return [dict get $providers $name profiles]
}

# {profiles {…names…} active <name>} for a provider; empty for one without
# profiles.
proc rio::agent::profiles {{name ""}} {
	variable providers
	set name [_key_target $name]
	if {![dict exists $providers $name] || ![dict exists $providers $name profiles]} {
		return [dict create profiles {} active ""]
	}
	set r [{*}[dict get $providers $name profiles list]]
	set ps [expr {[dict exists $r profiles] ? [dict get $r profiles] : {}}]
	set a  [expr {[dict exists $r active]   ? [dict get $r active]   : ""}]
	return [dict create profiles $ps active $a]
}

# The active profile's name, "" for a provider without profiles (agent.status).
proc rio::agent::profile_name {{name ""}} {
	return [dict get [profiles $name] active]
}

# Switch, create, remove, rename. Each returns what the provider settled on:
# a remove, for one, says which profile is active now.
proc rio::agent::profile_set {profile {name ""}} {
	set name [_key_target $name]
	set caps [_profiles_caps $name]
	return [{*}[dict get $caps switch] $profile]
}

proc rio::agent::profile_add {profile {from ""} {name ""}} {
	set name [_key_target $name]
	set caps [_profiles_caps $name]
	return [{*}[dict get $caps add] $profile $from]
}

proc rio::agent::profile_remove {profile {name ""}} {
	set name [_key_target $name]
	set caps [_profiles_caps $name]
	return [{*}[dict get $caps remove] $profile]
}

proc rio::agent::profile_rename {profile to {name ""}} {
	set name [_key_target $name]
	set caps [_profiles_caps $name]
	return [{*}[dict get $caps rename] $profile $to]
}

# The `agent.options` event: this provider's options changed, list them again.
# - It carries the provider's name, not the options: an event is a flat object
#   on the wire, and a re-list reads the list as it is now.
# - `error` reports a failed refresh, whose reply is long gone.
proc rio::agent::announce_options {name emit {error ""}} {
	{*}$emit [dict create event agent.options \
		params [dict create provider $name error $error]]
	return
}

# Clear the conversation (agent.reset) and abort every turn in flight.
proc rio::agent::reset {} {
	variable conversation
	_abort_all
	set conversation {}
	return
}

# Abort one turn: cancel its running command, delete its coroutine, forget its
# bookkeeping. Returns 1 only if the turn was live (D104). Reset, a new
# message and Stop all come through here.
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
	variable scopes
	unset -nocomplain live($t) pending($t) proposals($t) running($t) scopes($t)
	return $was
}

# Abort every turn, one waiting on its provider included (D104). Returns how
# many were live.
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

# The conversation so far (agent.history), as {role text} dicts. An entry
# without a text block (tool traffic only) is left out.
proc rio::agent::history {} {
	variable conversation
	set out {}
	foreach m $conversation {
		if {![_has_text $m]} continue
		lappend out [dict create role [dict get $m role] text [_text_of $m]]
	}
	return $out
}

# Make the conversation safe to extend. A turn abandoned at the approval gate
# leaves a tool_use without a tool_result, which the Messages API rejects. So:
# abort every turn in flight, and return an "interrupted" tool_result for each
# dangling tool_use. `send` puts them at the head of the new user message.
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

# Start a turn: record the user message, start the coroutine, return the ack
# {started turn}. The content follows as agent.* events on `emit` (D26).
#
# `scope` (D113) is {buffer start end original}, or {} for an ordinary turn.
# The selection is appended to the user message, so agent.history shows what
# the model was given (D105). A scope lasts one turn.
proc rio::agent::send {text emit {scope {}}} {
	variable conversation
	variable turnseq
	variable scopes
	set seal [_seal_dangling]
	variable live
	set turn [incr turnseq]
	if {[llength $scope]} {
		set scopes($turn) $scope
		append text "\n\n" [_scope_block $scope]
	}
	lappend conversation [dict create role user \
		content [concat $seal [list [dict create type text text $text]]]]
	# Register before starting: `coroutine` runs the body to its first yield,
	# and a turn that never yields clears its entry on the way out.
	set co [namespace current]::_turn_$turn
	set live($turn) $co
	coroutine $co [namespace current]::_run_guarded $turn $emit
	return [dict create result [dict create started true turn $turn]]
}

# _run, with its `live` entry cleared however it returns (D104).
proc rio::agent::_run_guarded {turn emit} {
	variable live
	variable scopes
	try {
		_run $turn $emit
	} finally {
		unset -nocomplain live($turn) scopes($turn)
	}
}

# The selection as the model reads it (D113): buffer, lines, the text in a
# fence. The fence is longer than any backtick run in the text.
proc rio::agent::_scope_block {scope} {
	set id  [dict get $scope buffer]
	set old [dict get $scope original]
	set l1 [lindex [split [dict get $scope start] .] 0]
	lassign [split [dict get $scope end] .] l2 c2
	if {$l2 > $l1 && $c2 == 0} { incr l2 -1 }
	set where [expr {$l1 == $l2 ? "line $l1" : "lines $l1–$l2"}]
	set fence "```"
	while {[string first $fence $old] >= 0} { append fence "`" }
	return "The request is about this selection in [rio::agent::tools::bufname $id]\
		(buffer $id, $where). Change only the selected text: replace_selection is the\
		only tool that edits, and it replaces exactly this text.\n\n$fence\n$old\n$fence"
}

# Stop a turn in flight (agent.stop, D104). No `turn` stops every live one.
# Returns the turns stopped; one already finished is not an error.
#
# A request already sent is not recalled: its answer is dropped by _resume,
# and it is still billed.
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

# Keep roles alternating after a stop. A turn stopped before `done` recorded
# no assistant entry, so the next `send` would add a second user entry in a
# row, which the Messages API rejects. A short assistant note fills the gap.
# A turn stopped at the approval gate needs none: see _seal_dangling.
proc rio::agent::_close_interrupted {} {
	variable conversation
	set last [lindex $conversation end]
	if {![llength $last] || [dict get $last role] ne "user"} return
	lappend conversation [dict create role assistant \
		content [list [dict create type text text "(Stopped by the user.)"]]]
}

# The loop. Each pass calls the provider, yields for what it posts back, maps
# each post onto an agent.* event, records the assistant turn and, if the
# model asked for tools, runs them and goes round again.
#
# The provider contract: `{*}$provider conversation tools system post`
#   tools   the tool specs (rio::agent::tools::specs)
#   system  the composed system prompt (rio::agent::prompt::compose)
#   {*}$post delta <text>                 a chunk of assistant text
#   {*}$post thinking <text>              a chunk of reasoning: shown, never
#                                         recorded, so never re-sent or billed
#   {*}$post tool  <id> <name> <in> <raw> a tool call (in = parsed dict,
#                                         raw = the input JSON)
#   {*}$post done  ?stop_reason?          this step is finished; "tool_use"
#                                         means: run the tools, continue
#   {*}$post error <code> <message>       the turn failed (D26)
#
# An unknown verb is ignored, so a provider written for a newer rio still runs.
proc rio::agent::_run {turn emit} {
	variable conversation
	variable provider
	variable scopes
	set co [info coroutine]
	while {1} {
		# Every step, not once a turn: approving a plan changes the mode mid-turn
		# (D101), and with it the tools and the prompt.
		set toolspecs [rio::agent::tools::specs [mode] [info exists scopes($turn)]]
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
				thinking {
					# Shown, not appended to `acc`: `acc` is recorded and re-sent.
					{*}$emit [dict create event agent.thinking \
						params [dict create turn $turn text [lindex $msg 1]]]
				}
				tool {
					lassign $msg _ id name input raw
					lappend calls [dict create id $id name $name input $input raw $raw]
					# Announce a read now. A gated call is announced below, as
					# agent.propose.
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
				default {}   ;# a newer provider's verb: ignored, never fatal (see above)
			}
		}
		if {$failed} return

		# Record the assistant turn: its text and its tool_use blocks.
		set blocks {}
		if {$acc ne ""} { lappend blocks [dict create type text text $acc] }
		foreach c $calls {
			lappend blocks [dict create type tool_use \
				id [dict get $c id] name [dict get $c name] \
				input [dict get $c input] raw [dict get $c raw]]
		}
		lappend conversation [dict create role assistant content $blocks]

		# The model is done: close the turn.
		if {$stop ne "tool_use" || ![llength $calls]} {
			{*}$emit [dict create event agent.message \
				params [dict create turn $turn role assistant text $acc]]
			return
		}

		# Run each tool and collect its result. A read runs at once; the other
		# kinds wait at the approval gate.
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

# One write call: prepare a proposal, emit it (agent.propose, with the diff),
# then auto-accept or yield until agent.approve brings the user's decision.
# Approved, the edit applies and its buffer.changed events are forwarded.
# Returns {ok content summary} for the tool_result.
proc rio::agent::_do_write {turn id name input emit co} {
	variable pending
	variable auto_accept
	variable proposals
	variable scopes
	set scope [expr {[info exists scopes($turn)] ? $scopes($turn) : {}}]
	set prep [rio::agent::tools::prepare_write $name $input $scope]
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
	# The scope moves onto the new text (D113), so a second replace_selection
	# replaces what the first wrote.
	if {[dict exists $r scope] && [info exists scopes($turn)]} {
		set scopes($turn) [dict get $r scope]
	}
	if {[dict exists $r events]} {
		foreach ev [dict get $r events] { {*}$emit $ev }
	}
	{*}$emit [dict create event agent.tool_result \
		params [dict create turn $turn id $id name $name \
			ok [dict get $r ok] summary [dict get $r summary]]]
	return $r
}

# One run_command call (D83): prepare the command, emit it (agent.propose,
# kind command), and yield for the user's decision.
# - auto_accept never applies: it is for edits only.
# - An allow-list rule the user wrote skips the wait (D84).
# - The command runs asynchronously (rio::exec::start); the loop yields again
#   until it completes. `running` holds it so an abort can kill it.
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
	# Standing approval (D84). `auto` tells the frontend the command ran without
	# asking. Only the confirmation is skipped; prepare_exec's guards applied.
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

# One present_plan call (D101): file the plan, emit it (agent.propose, kind
# plan, with the Markdown), and yield for the user's decision.
# - Always gated: auto_accept is for edits only (D83).
# - Approved: the mode becomes `build`, and the model is told to carry it out.
# - Rejected: the mode stays, and the model should plan again.
# - The plan file is re-read at approval (D102). If the user edited it, the
#   tool_result carries their version.
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
	# A plan can be presented from any mode (D103): announce a mode change only
	# if there is one.
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

# rio::exec::start's completion callback: resume the turn with the result.
proc rio::agent::_exec_done {co result} {
	after 0 [list [namespace current]::_resume $co $result]
}

# Resolve a pending approval (agent.approve): resume the turn with "approve"
# or "reject". An edit, a command and a plan all wait in `pending`.
proc rio::agent::approve {turn decision} {
	variable pending
	if {![info exists pending($turn)]} {
		rio::error::raise bad_request "no edit is awaiting approval for turn $turn"
	}
	lassign $pending($turn) co id
	after 0 [list [namespace current]::_resume $co $decision]
	return $id
}

# A pending write's full texts (agent.proposal, D28): original and proposed.
# The compare view pulls them when opened, so agent.propose stays small.
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

# Provider -> loop. Deferred, because a provider may post before the loop has
# yielded. A post for a coroutine that is gone is dropped.
proc rio::agent::_post {co args} {
	after 0 [list [namespace current]::_resume $co $args]
}
proc rio::agent::_resume {co msg} {
	if {[llength [info commands $co]]} { $co $msg }
}

# The built-in echo provider: the smallest implementation of the contract, and
# a test of the streaming path without a network. It echoes the last user
# message word by word, one event-loop turn each, then posts done. It ignores
# `tools` and `system`.
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

# Always available. Other providers register when the core loads them.
rio::agent::register_provider echo ::rio::agent::echo_provider -label Echo

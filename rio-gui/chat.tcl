# rio-gui/chat.tcl — the agent chat pane.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The agent chat pane (D14 `chat` column; D20/D26/D30). A dumb view (D3)
# over the agent.* event stream: a read-only transcript, a composer, and Send.
# agent.send is a STREAMING op — its reply is an ack, and the turn's content arrives
# as agent.delta events the core broadcasts over the channel (D30), routed here by
# dispatch_event and appended live (chat_event), so the answer builds in view;
# agent.message closes the turn, agent.error shows a classified failure (D26). The
# core owns the conversation (D3): chat_clear is agent.reset. Right side; toggleable.
# ---------------------------------------------------------------------------
# Insert into the read-only transcript (briefly enabled), scrolling to the end.
proc chat_log {text {tag ""}} {
	.chat.log configure -state normal
	if {$tag eq ""} { .chat.log insert end $text } else { .chat.log insert end $text $tag }
	.chat.log configure -state disabled
	.chat.log see end
}
# A speaker label opening a block (a blank line between blocks, not at the top).
proc chat_label {tag label} {
	if {[.chat.log index "end-1c"] ne "1.0"} { chat_log "\n" }
	chat_log "$label\n" $tag
}

# Send the composer's text as a turn (D26). agent.send is a streaming op: its reply
# is just an ack — the turn's content streams back afterward as agent.* events the
# core broadcasts over the channel, landing in chat_event via dispatch_event (D30).
proc chat_send {} {
	set text [string trim [.chat.input get 1.0 end]]
	if {$text eq ""} return
	.chat.input delete 1.0 end
	chat_send_text $text
}

# The one path a turn leaves the GUI by — the composer above, and Change with Agent…
# (D113), which passes the selection's `scope` {buffer start end} and a `note` saying
# what the request is about, shown muted under the user's words.
proc chat_send_text {text {scope {}} {note ""}} {
	# Sending a new message abandons any proposal still awaiting a decision; the core
	# seals the dangling tool call, so dismiss its review UI here to match (D28).
	if {$::pending_turn ne ""} { approve_bar 0 ; compare_close ; plan_close }
	chat_label you-label "You"
	chat_log "$text\n"
	if {$note ne ""} { chat_log "· $note\n" tool }
	set ::chat_turn_open 0 ; set ::chat_thinking_open 0
	set params [dict merge [dict create text $text] $scope]
	set resp [rio_call agent.send $params]
	if {![dict get $resp ok]} {
		set e [dict get $resp error]
		chat_label error-label "Error"
		chat_log "[dict get $e message] ([dict get $e code])\n"
	} else {
		chat_busy_start   ;# the turn is in flight — animate until it replies (D82)
	}
}

# Apply one streamed agent.* event to the transcript.
proc chat_event {ev} {
	set name [dict get $ev event]
	# Anything that is not more reasoning ends the run of it — one place, rather than a
	# close in every other arm, and the rule is exactly "the model moved on".
	if {$name ne "agent.thinking" && $::chat_thinking_open} {
		chat_log "\n" ; set ::chat_thinking_open 0
	}
	switch -- $name {
		agent.delta {
			if {!$::chat_turn_open} { chat_label agent-label "Agent" ; set ::chat_turn_open 1 }
			chat_log [dict get $ev params text]
		}
		agent.thinking {
			# The model's reasoning (provider-api 4): shown muted and indented, because
			# it is not the answer — the core never records it, so it is not re-sent on a
			# later step either. A local thinking model can spend a whole short turn
			# here, and the alternative to showing it is an empty reply.
			#
			# It stays in the transcript once the answer starts. Everything else written
			# to this log is append-only, a mid-stream delete would take any selection
			# the user made while reading with it, and a multi-step turn interleaves
			# several of these with tool calls — there is no principled rule for which to
			# erase. The way not to see it is the provider's own setting.
			if {!$::chat_turn_open} { chat_label agent-label "Agent" ; set ::chat_turn_open 1 }
			if {!$::chat_thinking_open} {
				chat_log "· thinking\n" tool
				set ::chat_thinking_open 1
			}
			chat_log [dict get $ev params text] thinking
		}
		agent.message {
			# A provider that didn't stream deltas still shows its full reply.
			if {!$::chat_turn_open} {
				chat_label agent-label "Agent"
				chat_log [dict get $ev params text]
			}
			chat_log "\n"
			set ::chat_turn_open 0
			chat_busy_stop   ;# turn done (D82)
		}
		agent.error {
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_busy_stop   ;# turn failed (D82)
			approve_bar 0
			chat_label error-label "Error"
			chat_log "[dict get $ev params message] ([dict get $ev params code])\n"
		}
		agent.stopped {
			# The user stopped the turn (D104) — here or in another frontend attached to
			# the same core. Not an error: it did what it was told, so it gets the muted
			# tool styling rather than the red error label. Any review UI the turn had put
			# up is asking about a decision nothing waits for now.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_busy_stop
			approve_bar 0 ; compare_close ; plan_close
			chat_log "· stopped\n" tool
		}
		agent.tool {
			# A read-only tool the agent is running (D26 slice 4) — auto-executed, so
			# this is transparency, not a prompt. Shown on its own line, mid-turn.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set args [dict get $ev params args]
			chat_log "· [dict get $ev params name][expr {$args eq "" ? "" : " $args"}]\n" tool
		}
		agent.propose {
			# A proposed action awaiting the user's decision. Two kinds (D26 s5, D83):
			# an EDIT carries a diff (auto-accept may skip the gate); a run_command
			# carries the argv and is ALWAYS gated (never auto-run, even under
			# auto-accept edits — running a command is the more dangerous act).
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set turn [dict get $ev params turn]
			set kind [expr {[dict exists $ev params kind] ? [dict get $ev params kind] : "edit"}]
			if {$kind eq "plan"} {
				# A plan (D101): always gated, and always opened — a plan the user has to
				# go looking for is a plan they will approve unread. The chat keeps the
				# one-line trace and the decision; the plan itself gets the center.
				chat_log "· presents a plan: [dict get $ev params title]\n" tool
				if {[dict get $ev params path] ne ""} {
					chat_log "  saved as [dict get $ev params path]\n" tool
				}
				plan_open [dict get $ev params title] [dict get $ev params plan] \
					[dict get $ev params path]
				set ::pending_turn $turn
				approve_bar 1 "Start work on this plan?" 0 0 1
				chat_busy_stop   ;# now waiting on the user, not the model (D82)
			} elseif {$kind eq "command"} {
				set argv [expr {[dict exists $ev params command] ? [dict get $ev params command] : {}}]
				set disp [dict get $ev params display]
				set auto [expr {[dict exists $ev params auto] ? [dict get $ev params auto] : 0}]
				if {$auto} {
					# Covered by an allow-list rule (D84): it runs without a bar. Show
					# what ran and keep the busy indicator — the turn is still working.
					chat_log "· runs run_command (allowed)\n" tool
					chat_command_preview $disp [dict get $ev params cwd]
				} else {
					chat_log "· proposes run_command\n" tool
					chat_command_preview $disp [dict get $ev params cwd]
					set ::pending_turn $turn
					set ::pending_cmd_argv $argv
					chat_allow_menu_populate $argv $disp
					approve_bar 1 "Run this command?" 0 1
					chat_busy_stop   ;# now waiting on the user, not the model (D82)
				}
			} else {
				# A *complex* edit (more than ::compare_threshold diff lines) opens in the
				# side-by-side compare view instead of dumping the whole diff inline —
				# unless the user turned that off (Settings ▸ Compare complex edits) (D28).
				set diff [dict get $ev params diff]
				chat_log "· proposes [dict get $ev params name]: [dict get $ev params path]\n" tool
				set complex [expr {[llength [split $diff "\n"]] > $::compare_threshold}]
				if {$::agent_compare_complex && $complex && !$::agent_auto_accept \
						&& [compare_proposal $turn]} {
					chat_log "  (opened in compare view)\n" tool
				} else {
					chat_diff $diff
				}
				if {!$::agent_auto_accept} {
					set ::pending_turn $turn
					approve_bar 1
					chat_busy_stop   ;# now waiting on the user, not the model (D82)
				}
			}
		}
		agent.mode {
			# The core changed the mode itself — approving a plan turns plan mode off
			# (D101). Mirror it, or the control would go on claiming the agent is planning
			# while it edits.
			set ::agent_plan_mode [expr {[dict get $ev params mode] eq "plan"}]
			agent_mode_sync
		}
		agent.options {
			# A provider's options changed — here, in another window (D3/D30), or because
			# a refresh has just come back from the network. The event says only THAT they
			# changed, so re-read: the list we then render is the list as it is now.
			set who [dict get $ev params provider]
			set err [expr {[dict exists $ev params error] ? [dict get $ev params error] : ""}]
			# A failure belongs where the user is looking. The settings window has a
			# status line of its own; the strip has nowhere but a dialog.
			if {$err ne ""} {
				if {[provider_settings_showing $who]} {
					after idle [list provider_settings_status $err 1]
				} else {
					report_error $err
				}
			}
			# Re-read from the IDLE loop, not from here: this handler runs inside the
			# channel reader, and an op call from there would nest one vwait inside
			# another. The repaint is not urgent — nothing is waiting on it.
			#
			# Two surfaces, guarded separately. The strip shows the ACTIVE provider, so
			# it repaints only for that one — but the settings window can be open on any
			# provider, and with only the first test a ⟳ Refresh there did nothing at all.
			if {$who eq $::agent_provider} { after idle agent_options_refresh }
			provider_settings_repaint $who
		}
		agent.tool_result {
			# The outcome of a read or an applied/rejected edit (red if it failed).
			approve_bar 0
			set tag [expr {[dict get $ev params ok] ? "tool" : "tool-error"}]
			chat_log "  → [dict get $ev params summary]\n" $tag
		}
	}
}

# Render a proposed command for review (D83): the shell-style command line (no tag,
# so it reads in the plain foreground — the human must read it before approving) and,
# when it isn't the project root, the directory it runs in. Display only: the core
# runs the argument vector directly, never through a shell.
proc chat_command_preview {display cwd} {
	chat_log "  \$ $display\n"
	if {$cwd ne ""} { chat_log "  in $cwd/\n" tool }
}

# Render a proposed edit's diff: -removed in red, +added in green.
proc chat_diff {diff} {
	foreach line [split $diff "\n"] {
		set tag tool
		if {[string match "+*" $line]} { set tag diff-add } elseif {[string match {-*} $line]} { set tag diff-del }
		chat_log "  $line\n" $tag
	}
}

# Show/hide the Approve/Reject bar for a pending proposal. `prompt` is the bar's
# question (an edit vs. a command vs. a plan each ask differently); `compare` shows the
# edit-only Compare button (a command has no diff to compare, D83); `always` shows the
# command-only "Always allow" menubutton (standing approval, D84 — an edit has no
# allow-list); `plan` shows the plan-only Plan button, which reopens a plan the user
# closed while thinking about it (D101). The extra buttons default off, so an edit shows
# just Approve/Reject.
proc approve_bar {show {prompt "Apply this edit?"} {compare 1} {always 0} {plan 0}} {
	if {!$show} {
		catch {pack forget .chat.approve}
		set ::pending_turn ""
		return
	}
	.chat.approve.lbl configure -text $prompt
	foreach w {yes appr edit no cmp always plan} { catch {pack forget .chat.approve.$w} }
	if {$plan} {
		# Approve ▾ | Edit plan | Reject | Plan, right to left (D102). A plan with no
		# project behind it was filed nowhere, so there is no file to edit.
		pack .chat.approve.appr -side right
		if {$::plan_path ne ""} { pack .chat.approve.edit -side right }
		pack .chat.approve.no   -side right
		pack .chat.approve.plan -side right
	} else {
		pack .chat.approve.yes -side right
		pack .chat.approve.no  -side right
		if {$always}  { pack .chat.approve.always -side right }
		if {$compare} { pack .chat.approve.cmp    -side right }
	}
	pack .chat.approve -side bottom -fill x -before .chat.input
}

# Rebuild the "Always allow" menu for the currently proposed command (D84). Two
# granularities as cascades — the program (argv[0], the recommended default: trust every
# invocation) first, the exact command line (trust only this identical argv) second —
# and each opens a submenu picking the SCOPE the rule is saved in: all projects (global),
# this project, or the active provider only. A long exact command is truncated in the
# label only. Each leaf remembers the rule (agent.allow.add) and approves the command in
# front of the user (agent_allow_always).
proc chat_allow_menu_populate {argv display} {
	set m .chat.approve.always.m
	$m delete 0 end
	# Which scopes are available right now.
	set pr [rio_result project.get {}]
	set haveproj [expr {$pr ne "" && [dict get $pr root] ne ""}]
	set prov [expr {[info exists ::agent_provider] ? $::agent_provider : ""}]
	set provok [expr {$prov ne "" && $prov ne "echo"}]
	set provlabel [expr {$provok ? [agent_provider_label $prov] : ""}]
	set prog [lindex $argv 0]
	set exact $display
	if {[string length $exact] > 40} { set exact "[string range $exact 0 39]…" }
	# (submenu suffix, cascade label, the rule)
	foreach {suf label rule} [list \
			prog  "Always allow: $prog"                        [list $prog] \
			exact "Always allow this exact command: $exact"    $argv] {
		set sm $m.$suf
		destroy $sm
		menu $sm -tearoff 0 -font RioUIFont
		$sm add command -label "For all projects" \
			-command [list agent_allow_always $rule global ""]
		$sm add command -label "For this project only" \
			-command [list agent_allow_always $rule project ""] \
			-state [expr {$haveproj ? "normal" : "disabled"}]
		if {$provok} {
			$sm add command -label "While $provlabel is the provider" \
				-command [list agent_allow_always $rule provider $prov]
		}
		$m add cascade -label $label -menu $sm
	}
}

# Persist a trust rule in a scope, then approve the command now in front of the user
# (D84). "Always allow" = remember + run this one. Add first (so a failed write still
# leaves the command awaiting the plain decision), then decide.
proc agent_allow_always {rule scope name} {
	if {$::pending_turn eq ""} return
	catch {rio_call agent.allow.add [dict create rule $rule scope $scope name $name]}
	agent_decide approve
}

# The user's decision on the pending edit → agent.approve resumes the turn, whose
# remaining events stream back as broadcast agent.* events (dispatch_event → chat).
# Approve a plan, saying how the work it starts should go (D102). The policy is decided
# HERE, on the plan, rather than inherited from a flag set before the user knew what would
# be proposed — which is what let auto-accept sit armed behind "plan mode". Set the flag
# first, so a failed write leaves the plan still awaiting a decision instead of starting
# work under a policy the core never accepted.
proc agent_decide_plan {policy} {
	if {$::pending_turn eq ""} return
	set on [expr {$policy eq "auto"}]
	set r [rio_call agent.autoaccept.set [dict create on $on]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	set ::agent_auto_accept $on
	agent_mode_sync
	agent_decide approve
}

proc agent_decide {decision} {
	if {$::pending_turn eq ""} return
	set t $::pending_turn
	approve_bar 0
	compare_close
	plan_close
	catch {rio_call agent.approve [dict create turn $t decision $decision]}
	chat_busy_start   ;# the turn resumes; the next message/error stops it (D82)
}

# Clear the conversation: reset the core's state (agent.reset) and the transcript.
proc chat_clear {} {
	rio_call agent.reset {}
	chat_busy_stop   ;# abort any working animation (D82)
	# agent.reset aborts any turn suspended at the approval gate, so the review UI is now
	# asking about a decision nothing is waiting for — take it down with the conversation
	# it belonged to. Most visible with a plan (D101), which holds the whole center.
	approve_bar 0 ; compare_close ; plan_close
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	set ::chat_turn_open 0 ; set ::chat_thinking_open 0
}

# Show/hide the chat pane by tab presence (kept for callers that flip the ::chat_shown
# mirror directly, e.g. tests). Give chat a tab (foreground) or take it away, re-derive,
# then apply_layout syncs the mirror back so the two never drift.
proc apply_chat_visibility {} {
	set s [rio::layout::site_of chat]
	if {$::chat_shown} { rio::layout::unhide $s chat ; rio::layout::put $s active chat } else { rio::layout::hide $s chat }
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	if {$::chat_shown} { focus .chat.input }
}

# Drag the csash to resize the RIGHT site (always on the right edge; D35 c1b). Its
# width is the toplevel's right edge minus the pointer — measured against the
# toplevel's STABLE edge like sash_drag. Clamped so neither side collapses.
proc csash_drag {} {
	set total [winfo width .]
	set min 200
	set max [expr {$total - 250}]
	set w [expr {[winfo rootx .] + $total - [winfo pointerx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteright configure -width $w
}

# Drag the bsash to resize the BOTTOM site's height (D35). Its bottom edge is fixed
# just above the status bar, so the height is the window's bottom minus the status
# bar minus the pointer — measured against the toplevel's STABLE edge like sash_drag.
proc bsash_drag {} {
	set total [winfo height .]
	set min 60
	set max [expr {$total - 150}]
	set h [expr {[winfo rooty .] + $total - [winfo height .status] - [winfo pointery .]}]
	if {$h < $min} { set h $min }
	if {$max > $min && $h > $max} { set h $max }
	.sitebottom configure -height $h
}

# Drag the composer sash to resize the input box. Its height is in text lines, so we
# anchor on the press (start height + pointer y) and convert the vertical drag to a
# line delta via the font's line height — dragging up grows the input, down shrinks
# it. Clamped so it can't vanish or eat the whole transcript.
proc isash_press {y} {
	set ::isash_y0 $y
	set ::isash_h0 [.chat.input cget -height]
}
proc isash_drag {y} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set h [expr {$::isash_h0 + int(double($::isash_y0 - $y) / $lh + 0.5)}]
	if {$h < 1} { set h 1 }
	set max [chat_input_max]
	if {$h > $max} { set h $max }
	.chat.input configure -height $h
}
# The most lines the input may take while leaving the sash and a few transcript
# lines on screen — otherwise a maxed input squeezes the divider out of reach.
proc chat_input_max {} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set avail [expr {[winfo height .chat] - [winfo height .chat.hdr] \
		- [winfo height .chat.status] - [winfo height .chat.send] \
		- [winfo reqheight .chat.isash] - 3 * $lh}]
	set m [expr {$avail / $lh}]
	if {$m < 1} { set m 1 }
	return $m
}
# Re-clamp on layout changes (chat shown, window resized) so the input never hides
# the sash — and a previously over-tall input shrinks back into reach on its own.
proc clamp_input_height {} {
	set m [chat_input_max]
	if {[.chat.input cget -height] > $m} { .chat.input configure -height $m }
}

# --- the agent "working" indicator (D82) -------------------------------------
# Begin animating: a turn is now being worked. Idempotent — cancels any pending tick
# first, so a fresh send (or a resumed turn) just restarts the cycle from a new phrase.
proc chat_busy_start {} {
	after cancel $::chat_busy_after
	set ::chat_busy 1
	set ::chat_busy_frame 0
	set ::chat_busy_word [lindex $::chat_busy_words \
		[expr {int(rand() * [llength $::chat_busy_words])}]]
	chat_busy_render
	chat_send_button
	set ::chat_busy_after [after 400 chat_busy_tick]
}
# One animation frame: advance the dots every tick and the phrase every ~2.4 s, then
# reschedule. A stray tick after a stop is a no-op (guarded on ::chat_busy).
proc chat_busy_tick {} {
	if {!$::chat_busy} return
	incr ::chat_busy_frame
	if {$::chat_busy_frame % 6 == 0} {
		set ::chat_busy_word [lindex $::chat_busy_words \
			[expr {int(rand() * [llength $::chat_busy_words])}]]
	}
	chat_busy_render
	set ::chat_busy_after [after 400 chat_busy_tick]
}
# Paint the current phrase with a 1→2→3 "Please wait…" dot cycle. ASCII dots only, so no
# UI font can drop a glyph (the D54 Windows / Alpine / OpenBSD matrix).
proc chat_busy_render {} {
	set dots [string repeat "." [expr {$::chat_busy_frame % 3 + 1}]]
	catch {.chat.status.busy configure -text "$::chat_busy_word$dots"}
}
# Stop animating and clear the indicator's half of the strip (the agent selector beside
# it never went anywhere).
proc chat_busy_stop {} {
	after cancel $::chat_busy_after
	set ::chat_busy_after ""
	set ::chat_busy 0
	catch {.chat.status.busy configure -text ""}
	chat_send_button
	chat_status_update
}

# The composer's button follows the turn (D104): ▶ Send while it is yours to type into,
# ■ Stop while the agent is working. One button, because the two are never both available —
# and because a turn now runs until it is finished or stopped, so Stop must never be more
# than one click away. At the approval gate the animation stops and the button goes back to
# Send: the turn is parked, waiting on the bar, and there is nothing running to stop.
proc chat_send_button {} {
	if {![winfo exists .chat.send]} return
	if {$::chat_busy} {
		.chat.send configure -text "■" -command chat_stop
		tooltip .chat.send "Stop the agent"
	} else {
		.chat.send configure -text "▶" -command chat_send
		tooltip .chat.send "Send this message"
	}
}

# Stop the turn in flight. The core kills it and announces agent.stopped, which every
# attached frontend adopts (D3/D30) — including this one, so the transcript line and the
# indicator are written by the event, not here, and a stop from another window looks the
# same as a stop from this one.
proc chat_stop {} {
	set r [rio_call agent.stop {}]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	# Nothing was running: the click raced the turn's last event. Put the button back.
	if {[dict get $r result stopped] == 0} { chat_busy_stop }
}

# The status strip names the live agent, and nothing else: the mode is stated once, by the
# header control that sets it (D102). Two places saying it was how the old strip came to lie
# — it showed "plan mode" over an armed auto-accept flag it had no room for. Since D106 the
# strip is a control, and it keeps answering while a turn runs: the working indicator has
# its own half.
proc chat_status_update {} {
	agent_options_sync
}

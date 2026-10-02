# rio-gui/chat.tcl — the agent chat pane.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The agent's chat pane (D20, D26): a view of the agent.* events. A read-only
# transcript, an input, Send. agent.send answers with an ack; the turn's
# content arrives as events (chat_event). The core owns the conversation:
# Clear is agent.reset.
# ---------------------------------------------------------------------------
# Append to the transcript and scroll to the end.
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

# Send the input's text as a turn.
proc chat_send {} {
	set text [string trim [.chat.input get 1.0 end]]
	if {$text eq ""} return
	.chat.input delete 1.0 end
	chat_send_text $text
}

# Send a turn: from the input, or from Change with Agent… (D113), which
# passes the selection's `scope` {buffer start end} and a `note` shown under
# the user's words.
proc chat_send_text {text {scope {}} {note ""}} {
	# A new message abandons a pending proposal: take its review UI down (D28).
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
	# Any other event ends a run of reasoning.
	if {$name ne "agent.thinking" && $::chat_thinking_open} {
		chat_log "\n" ; set ::chat_thinking_open 0
	}
	switch -- $name {
		agent.delta {
			if {!$::chat_turn_open} { chat_label agent-label "Agent" ; set ::chat_turn_open 1 }
			chat_log [dict get $ev params text]
		}
		agent.thinking {
			# The model's reasoning (provider-api 4): muted and indented. It
			# stays in the transcript; the log is append-only.
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
			# The turn was stopped (D104), here or from another frontend. Not an
			# error. Its review UI goes too.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_busy_stop
			approve_bar 0 ; compare_close ; plan_close
			chat_log "· stopped\n" tool
		}
		agent.tool {
			# A read tool is running. Shown for information.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set args [dict get $ev params args]
			chat_log "· [dict get $ev params name][expr {$args eq "" ? "" : " $args"}]\n" tool
		}
		agent.propose {
			# A proposal waits for the user: an edit (a diff; auto-accept may
			# skip the wait), a command (always asks, D83) or a plan (D101).
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set turn [dict get $ev params turn]
			set kind [expr {[dict exists $ev params kind] ? [dict get $ev params kind] : "edit"}]
			if {$kind eq "plan"} {
				# A plan is always opened, in the centre; the chat keeps one line
				# and the decision.
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
					# Allowed by a rule (D84): it runs without asking.
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
				# An edit of more than ::compare_threshold diff lines opens in the
				# compare view (D28), unless the user turned that off.
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
			# The core changed the mode: approving a plan ends plan mode (D101).
			set ::agent_plan_mode [expr {[dict get $ev params mode] eq "plan"}]
			agent_mode_sync
		}
		agent.options {
			# A provider's options changed: read them again.
			set who [dict get $ev params provider]
			set err [expr {[dict exists $ev params error] ? [dict get $ev params error] : ""}]
			# A failure goes to the settings window's status line if it is
			# open, else to a dialog.
			if {$err ne ""} {
				if {[provider_settings_showing $who]} {
					after idle [list provider_settings_status $err 1]
				} else {
					report_error $err
				}
			}
			# From the idle loop: this runs inside the channel reader, where an
			# op call would nest. The strip shows the active provider only; the
			# settings window may show any.
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

# Show a proposed command (D83): the command line in the plain text colour,
# and its directory if not the project root. Display only: the core runs the
# argv, never a shell.
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

# Show or hide the approval bar.
#   prompt   the bar's question
#   compare  the Compare button (edits)
#   always   the "Always allow" menu (commands, D84)
#   plan     the plan's buttons (D101, D102)
proc approve_bar {show {prompt "Apply this edit?"} {compare 1} {always 0} {plan 0}} {
	if {!$show} {
		catch {pack forget .chat.approve}
		set ::pending_turn ""
		return
	}
	.chat.approve.lbl configure -text $prompt
	foreach w {yes appr edit no cmp always plan} { catch {pack forget .chat.approve.$w} }
	if {$plan} {
		# Right to left: Approve ▾, Edit plan (if the plan is a file),
		# Reject, Plan (D102).
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

# Rebuild the "Always allow" menu for the proposed command (D84):
#
#   Always allow: git                        ▸ For all projects
#   Always allow this exact command: git …   ▸ For this project only
#                                              While <provider> is the provider
#
# A leaf adds the rule and approves this command.
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

# Add an allow rule, then approve the pending command (D84).
proc agent_allow_always {rule scope name} {
	if {$::pending_turn eq ""} return
	catch {rio_call agent.allow.add [dict create rule $rule scope $scope name $name]}
	agent_decide approve
}

# Approve a plan with a mode for the work it starts (D102): `review` or
# `auto`. The flag is set first: if that fails, the plan still waits.
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

# The user's decision on the pending proposal: agent.approve resumes the turn.
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
	# agent.reset aborts a turn waiting for approval: take its review UI down.
	approve_bar 0 ; compare_close ; plan_close
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	set ::chat_turn_open 0 ; set ::chat_thinking_open 0
}

# Apply ::chat_shown: give the chat a tab, in front, or take it away. For
# callers that set the variable directly, e.g. tests.
proc apply_chat_visibility {} {
	set s [rio::layout::site_of chat]
	if {$::chat_shown} { rio::layout::unhide $s chat ; rio::layout::put $s active chat } else { rio::layout::hide $s chat }
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	if {$::chat_shown} { focus .chat.input }
}

# Drag .csash: resize the right site. Its width is the toplevel's right edge
# minus the pointer. Clamped.
proc csash_drag {} {
	set total [winfo width .]
	set min 200
	set max [expr {$total - 250}]
	set w [expr {[winfo rootx .] + $total - [winfo pointerx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteright configure -width $w
}

# Drag .bsash: resize the bottom site. Its height is the window's bottom,
# minus the status bar, minus the pointer. Clamped.
proc bsash_drag {} {
	set total [winfo height .]
	set min 60
	set max [expr {$total - 150}]
	set h [expr {[winfo rooty .] + $total - [winfo height .status] - [winfo pointery .]}]
	if {$h < $min} { set h $min }
	if {$max > $min && $h > $max} { set h $max }
	.sitebottom configure -height $h
}

# Drag .chat.isash: resize the input. Its height is in lines, so the drag in
# pixels is divided by the font's line height. Up grows it. Clamped.
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
# The most lines the input may take: the sash and three transcript lines
# must stay on screen.
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
# Clamp again when the layout changes.
proc clamp_input_height {} {
	set m [chat_input_max]
	if {[.chat.input cget -height] > $m} { .chat.input configure -height $m }
}

# --- the agent "working" indicator (D82) -------------------------------------
# Start the animation: a turn is running. A second call restarts it.
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
# One frame: new dots every tick (400 ms), a new phrase every sixth.
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
# Paint the phrase with one to three dots. ASCII dots: every font has them.
proc chat_busy_render {} {
	set dots [string repeat "." [expr {$::chat_busy_frame % 3 + 1}]]
	catch {.chat.status.busy configure -text "$::chat_busy_word$dots"}
}
# Stop the animation and clear the indicator.
proc chat_busy_stop {} {
	after cancel $::chat_busy_after
	set ::chat_busy_after ""
	set ::chat_busy 0
	catch {.chat.status.busy configure -text ""}
	chat_send_button
	chat_status_update
}

# The button follows the turn (D104): ▶ Send, or ■ Stop while the agent is
# working. At the approval bar it is Send: nothing is running.
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

# Stop the running turn. The core announces agent.stopped; that event
# writes the transcript line, here and in every other frontend.
proc chat_stop {} {
	set r [rio_call agent.stop {}]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	# Nothing was running: put the button back.
	if {[dict get $r result stopped] == 0} { chat_busy_stop }
}

# The status strip names the provider and model. The mode is shown once, by
# the header's control (D102).
proc chat_status_update {} {
	agent_options_sync
}

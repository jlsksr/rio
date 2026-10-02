# rio-gui/prefs.tcl — sessions, preferences and the Preferences window.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Mirror whether the core keeps recovery copies of changed buffers (D132). Read at attach,
# never written then — the same rule as the agent's settings and the https switch, and for
# the same reason: the policy is the core's, because the copies land on ITS disk and a
# daemon autosaves buffers with no frontend attached at all. Quiet on failure, so a core
# that predates autosave.settings just leaves the checkbox showing its default.
proc adopt_autosave_settings {} {
	set r [rio_call autosave.settings {}]
	if {![dict get $r ok]} return
	set ::autosave_on [dict get $r result enabled]
	set ::autosave_interval [dict get $r result interval]
}

# How often the core writes a copy, in words. The interval is hand-editable in autosave.conf
# (D132), so the hint READS it rather than carrying a second copy of the number — which would
# then be the one that goes stale (§7). Say it once and derive the rest.
proc autosave_every {} {
	set secs [expr {$::autosave_interval / 1000}]
	if {$secs >= 60 && $secs % 60 == 0} {
		set mins [expr {$secs / 60}]
		return [expr {$mins == 1 ? "minute" : "$mins minutes"}]
	}
	return "$secs seconds"
}

proc autosave_hint {} {
	return "Every [autosave_every] rio writes a copy of each file you have\nchanged, so a crash or a power cut costs you at most that much.\nYour own file is never written until you save it: the copies live\nwith the core, outside your project, and rio offers them back the\nnext time you open the file."
}

# The applier behind the Preferences checkbox. Writes, then shows what the core ACCEPTED,
# so a refusal leaves the control honest rather than claiming a state the core is not in
# (tls_unchecked_set's shape).
proc autosave_set {} {
	set want $::autosave_on
	set ::autosave_on [expr {!$want}]
	set r [rio_call autosave.settings.set [dict create enabled $want]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	set ::autosave_on [dict get $r result enabled]
	set ::autosave_interval [dict get $r result interval]
}

# Mirror the core's https switch (D114) and what its tcltls can check. Same rule as the
# agent's settings: read at attach, never written then. Quiet on failure — a core that
# predates tls.settings just leaves the Network pane showing its defaults.
proc adopt_tls_settings {} {
	set r [rio_call tls.settings {}]
	if {![dict get $r ok]} return
	set st [dict get $r result]
	set ::tls_unchecked       [dict get $st unchecked]
	set ::tls_checks_hostname [dict get $st checks_hostname]
	set ::tls_version         [dict get $st tcltls]
	if {[winfo exists .prefs.body.network.hint]} {
		.prefs.body.network.hint configure -text [tls_unchecked_hint]
	}
}

# The writer behind Preferences ▸ Network ▸ "Allow https without host-name checks" (D110,
# core-wide since D114: the agent and extension repositories alike). The choice is the
# CORE's — its tcltls is the one in question, and every frontend attached to it shares the
# answer — so the checkbutton only asks, and shows what the core stored. A refusal puts
# the box back rather than leave it claiming a setting that isn't in force.
proc tls_unchecked_set {} {
	set want $::tls_unchecked
	set ::tls_unchecked [expr {!$want}]
	set r [rio_call tls.settings.set [dict create unchecked $want]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		return
	}
	set ::tls_unchecked [dict get $r result unchecked]
}

# The hint under that checkbox: what ticking it gives away, and whether it matters on the
# core this GUI is attached to.
proc tls_unchecked_hint {} {
	set what "Off: on a core whose tcltls is older than 1.8, the agent and https extension repositories refuse https — that tcltls accepts a valid certificate issued for any host, not just the server's. Turn on only on a network you trust, if tcltls can't be upgraded there. Plain http is never affected."
	if {$::tls_checks_hostname} {
		return "This core's tcltls checks host names, so this changes nothing here. $what"
	}
	if {$::tls_version ne ""} {
		return "This core has tcltls $::tls_version. $what"
	}
	return $what
}

# ---------------------------------------------------------------------------
# Sessions & preferences (D31). Two halves, split by owner:
#
#   * PREFERENCES — how the editor looks: theme, wrap, dock side/pane, chat
#     visibility. Pure view state the core knows nothing about, so the GUI owns it,
#     in $XDG_CONFIG_HOME/rio/prefs.json (beside the user themes dir). Plain JSON
#     data, parsed never executed (D21); loaded at startup, saved on each change.
#
#   * WORKSPACE — which files were open in a project + the active tab. Document
#     state, so the CORE owns it (workspace.* ops, keyed by project root, kept OUT
#     OF TREE under its data dir). That is why a resume Just Works over a remote
#     core: the session lives WITH the project, on the server (D30/D31).
#
# Neither ever holds a secret (the API key stays in the 0600 store, D26). Writes are
# gated on ::rio_started so the appliers that also run during boot don't persist the
# defaults back over what was just loaded.
# ---------------------------------------------------------------------------
proc prefs_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio prefs.json]
}

# Read a whole UTF-8 text file, ALWAYS closing the channel — the `finally` is the
# point. Each config reader below parses inside a catch that tolerates a corrupt
# file; written as one `open … ; parse ; close` chain, a throwing parse skips the
# close and leaks the channel. That is invisible on POSIX but not on Windows, where
# an open handle makes the file undeletable: one corrupt prefs.json or keys.json
# locked it for the life of the process, so rio could never rewrite or reset it.
proc slurp_utf8 {path} {
	set f [open $path r]
	try {
		fconfigure $f -encoding utf-8
		return [::read $f]
	} finally {
		close $f
	}
}

# Load saved preferences over the defaults. A missing or corrupt file leaves the
# defaults intact — a bad prefs file must never stop the editor starting. Only known
# keys with valid values are honoured; anything else is ignored.
proc prefs_load {} {
	set path [prefs_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {set d [json::json2dict [slurp_utf8 $path]]}]} return
	if {[dict exists $d theme]}      { set ::theme_name [dict get $d theme] }
	if {[dict exists $d wrap]}       { set ::wrap_lines [expr {[dict get $d wrap] ? 1 : 0}] }
	if {[dict exists $d wrap_indent]} { set ::wrap_indent [expr {[dict get $d wrap_indent] ? 1 : 0}] }
	if {[dict exists $d line_numbers]} { set ::line_numbers [expr {[dict get $d line_numbers] ? 1 : 0}] }
	if {[dict exists $d highlight_current_line]} { set ::highlight_current_line [expr {[dict get $d highlight_current_line] ? 1 : 0}] }
	if {[dict exists $d relative_line_numbers]} { set ::relative_line_numbers [expr {[dict get $d relative_line_numbers] ? 1 : 0}] }
	if {[dict exists $d show_hidden]} { set ::show_hidden [expr {[dict get $d show_hidden] ? 1 : 0}] }
	if {[dict exists $d column_edit]} { set ::col_on [expr {[dict get $d column_edit] ? 1 : 0}] }
	if {[dict exists $d check_updates]} { set ::ext_check_updates [expr {[dict get $d check_updates] ? 1 : 0}] }
	if {[dict exists $d allow_unverified_repos]} { set ::repo_allow_unverified [expr {[dict get $d allow_unverified_repos] ? 1 : 0}] }
	if {[dict exists $d agent_selection_menu]} { set ::agent_selection_menu [expr {[dict get $d agent_selection_menu] ? 1 : 0}] }
	if {[dict exists $d tab_layout]} {
		set tl [dict get $d tab_layout]
		if {$tl eq "scroll" || $tl eq "multi"} { set ::tab_layout $tl }
	}
	# Editor font override (D56). Applied by the first apply_theme after boot, which
	# overlays these onto the theme's font. A bad size is ignored, keeping the theme's.
	if {[dict exists $d font_family]} { set ::editor_font_family [dict get $d font_family] }
	if {[dict exists $d font_size]} {
		set s [dict get $d font_size]
		if {[string is integer -strict $s] && $s >= 5 && $s <= 72} { set ::editor_font_size $s }
	}
	# The dock layout (D35 step b): adopt a persisted `layout` object, or migrate the
	# pre-step-(b) flat keys (dock_side/dock_pane/chat_shown) forward. normalize repairs
	# either into a well-formed layout (and boots the Search strip hidden).
	if {[dict exists $d layout]} {
		set ::layout [rio::layout::boot [dict get $d layout]]
	} else {
		set ::layout [rio::layout::boot [rio::layout::migrate $d]]
	}
	if {[dict exists $d editmode]} { set ::edit_mode [dict get $d editmode] }
	# The last folder opened on a local core (D88). Stashed only — the project can't be
	# reopened until the channel is up; reopen_last_project does that during boot.
	if {[dict exists $d project]} { set ::last_project [dict get $d project] }
}

# Persist the current preferences. Called from each view-state applier (do_theme,
# apply_wrap, apply_layout, show_pane) — the single choke point per setting — so any
# menu or keyboard toggle records itself. Scalars are flat strings (rio::wire::obj);
# the dock arrangement rides as the nested `layout` object (D35 step b), which
# replaced the old dock_side/dock_pane/chat_shown flags outright (clean cut,
# decision 3). 0/1 flags read back cleanly through expr.
proc prefs_save {} {
	if {!$::rio_started} return
	set path [prefs_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set scalars [rio::wire::obj [dict create \
			theme       $::theme_name \
			wrap        $::wrap_lines \
			wrap_indent $::wrap_indent \
			line_numbers $::line_numbers \
			highlight_current_line $::highlight_current_line \
			relative_line_numbers $::relative_line_numbers \
			show_hidden $::show_hidden \
			column_edit $::col_on \
			check_updates $::ext_check_updates \
			allow_unverified_repos $::repo_allow_unverified \
			agent_selection_menu $::agent_selection_menu \
			tab_layout  $::tab_layout \
			font_family $::editor_font_family \
			font_size   $::editor_font_size \
			editmode   $::edit_mode \
			project    $::last_project]]
		# scalars minus its trailing brace, then the layout member and a final closing
		# brace (backslash-escaped so this literal brace does not end the catch body).
		set json "[string range $scalars 0 end-1],\"layout\":[rio::layout::json]\}"
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f $json ; close $f
	}
}

# Save the open project's workspace: the paths of the open tabs (untitled/unsaved
# tabs, which have no path, are omitted), the active tab's path, and the file tree's
# unfolded-dir set (D89). The core keys it by the open project root and no-ops when
# none is open, so this is safe to call unconditionally. `open` and `expanded` ride the
# wire as newline-joined strings (workspace.*). Unlike D88's project pointer, the tree
# shape lives in the core session, so it follows the project onto a remote host too.
proc session_save {} {
	if {!$::rio_started} return
	set paths {}
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p ne ""} { lappend paths $p }
	}
	set active [expr {$::cur ne "" ? [bufget $::cur path] : ""}]
	catch {rio_call workspace.save [dict create open [join $paths "\n"] active $active \
		expanded [join [dict keys $::nav_expanded] "\n"]]}
}

# Reopen the folder open at the last launch (D88), so a bare `rio` resumes where you
# left off instead of a blank pane. The core keeps "which folder is open" in memory only
# (rio::project — reset on a fresh process), so the GUI persists the path (prefs.json) and
# reopens it here, which is also what points workspace.get at the right per-project session
# below. Runs during boot before session_restore, only when nothing else already opened a
# project (an argv folder or an adopted core project wins). Local cores only: ::last_project
# is never set from a remote (server) root, and open_folder would report_error on a path the
# local core can't see. A folder that has since vanished is skipped silently.
proc reopen_last_project {} {
	if {$::nav_root ne "" || $::core_remote} return
	# The core owns "which folder is open": a persistent local daemon may already hold one,
	# so adopt that rather than overriding it with the remembered path (this also fills the
	# pane in the adopted-project case). Only when the core has none do we reopen last time's.
	set root [dict get [rio_call project.get {}] result root]
	if {$root ne ""} { on_project_opened [dict create root $root] ; return }
	if {$::last_project eq ""} return
	if {![file isdirectory $::last_project]} {
		# The remembered folder is gone from disk (deleted since we last ran). Stop pointing
		# launches at a dead path (D89) — the in-memory clear persists on the next prefs_save.
		set ::last_project ""
		return
	}
	open_folder $::last_project
}

# Restore the open project's workspace: reopen each saved file (the core has already
# pruned any that vanished) and focus the saved active tab. do_open dedups against
# open tabs and prunes the empty scratch buffer, so restoring onto a fresh launch
# leaves exactly the saved set. Runs during boot only, while ::rio_started is still 0
# — so the do_opens here don't each trigger a save.
proc session_restore {} {
	set resp [rio_call workspace.get {}]
	if {![dict get $resp ok]} return
	set res [dict get $resp result]
	foreach p [dict get $res open] { do_open $p }
	set active [dict get $res active]
	if {$active ne ""} {
		foreach id [dict keys $::buffers] {
			if {[bufget $id path] eq $active} { activate $id ; break }
		}
	}
	# Restore the file tree's unfolded shape (D89), now the project is open so this keys on
	# the right session. The core pruned any dir that has since vanished. on_project_opened
	# reset the set to empty when the folder opened; this refills it and repaints. Only with a
	# project actually open — the anonymous (no-folder) session has no tree.
	if {$::nav_root ne ""} {
		set ::nav_expanded [dict create]
		foreach d [dict get $res expanded] { dict set ::nav_expanded $d 1 }
		if {[dict size $::nav_expanded]} { populate_nav }
	}
}

# ---------------------------------------------------------------------------
# Preferences window (D58). One place to find every stateful setting as the
# count grows, so the top-level menus don't keep accreting checkbuttons. It does NOT own
# any state: each control drives the SAME global the menu entry binds (::wrap_lines,
# ::tab_layout, …) and calls the SAME applier, which persists via prefs_save. So it is
# live-apply (no Save/Cancel — a toggle takes effect at once, like every view toggle in
# rio), and the twin menu entry updates with it for free (Tk repaints a checkbutton the
# instant its -variable changes), and vice-versa. Commands (Zoom, Split, Compare) are
# actions, not preferences, and stay menu-only; keyboard shortcuts keep their own
# recorder (its working-copy model suits a half-typed chord), reached from a button here.
# ---------------------------------------------------------------------------
# Themed control factories: the menu-matching palette (D31 named fonts, theme_colors) in
# one place so each control is a single line. `args` passes extras through (e.g. the
# Multi-Line Tabs checkbutton's -onvalue/-offvalue).
proc prefs_check {w label var cmd args} {
	set c $::theme_colors
	checkbutton $w -text $label -variable $var -command $cmd -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg] {*}$args
	return $w
}
proc prefs_radio {w label var val cmd} {
	set c $::theme_colors
	radiobutton $w -text $label -variable $var -value $val -command $cmd -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg]
	return $w
}
proc prefs_label {w text} {
	set c $::theme_colors
	label $w -text $text -anchor w -justify left -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	return $w
}
proc prefs_button {w text cmd} { button $w -text $text -font RioUIFont -command $cmd ; return $w }
# A muted, greyed-out hint line (gutter.fg) — orientation text, styled apart from the
# interactive controls so it never reads as one (D68). Wraps within the pane width.
proc prefs_hint {w text {wrap 300}} {
	set c $::theme_colors
	label $w -text $text -anchor w -justify left -font RioUIFont -wraplength $wrap \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	return $w
}

# View category: the display cluster (the same controls as the View menu), the dock
# side, the theme button (onto the shared picker, which enumerates from the core so
# installed themes appear), and the Font… dialog button.
proc prefs_fill_view {f} {
	set r 0
	grid [prefs_check $f.wrap    "Wrap Lines"           ::wrap_lines  apply_wrap]        -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.wrapind "Indent Wrapped Lines" ::wrap_indent apply_wrap_indent] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.lnum    "Line Numbers"         ::line_numbers apply_line_numbers] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.curln   "Highlight Current Line" ::highlight_current_line apply_curline] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.relnum  "Relative Line Numbers"  ::relative_line_numbers apply_relnum] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.mtab    "Multi-Line Tabs"      ::tab_layout  tab_layout_apply \
		-onvalue multi -offvalue scroll] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_check $f.hidden  "Show Hidden Files"    ::show_hidden apply_show_hidden] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_label $f.dockl "Dock side"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_radio $f.dl "Left"  ::dock_side left  {dock_set_side left}]  -row [incr r] -column 0 -sticky w -padx {12 0}
	grid [prefs_radio $f.dr "Right" ::dock_side right {dock_set_side right}] -row [incr r] -column 0 -sticky w -padx {12 0}
	# A button carrying the current theme's pretty label (::theme_choice_label, kept live
	# by a trace) and opening the shared picker — the same door as View ▸ Theme…, so the
	# two stay in sync for free and do_theme applies + persists the pick. It was a
	# dropdown until D92; a menu can't bound its own height, and the theme list grows with
	# every installed theme (D39). Keeping the *value* on the button (not a bare "Theme…")
	# is what the dropdown was for: Preferences is the config home, so it shows what is set.
	grid [prefs_label $f.thl "Theme"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.theme "" theme_pick_dialog] -row [incr r] -column 0 -sticky w -padx {12 0}
	$f.theme configure -textvariable ::theme_choice_label -anchor w
	grid [prefs_label $f.fontl "Font"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.font "Font…" editor_font_dialog] -row [incr r] -column 0 -sticky w -padx {12 0} -pady {0 2}
}

# Editor category: the editing mode (enumerated from the registry like modes_menu_fill,
# so a mode extension shows up), and column editing.
proc prefs_fill_editor {f} {
	set r 0
	grid [prefs_label $f.eml "Editing Mode"] -row [incr r] -column 0 -sticky w
	if {[info commands rio::modes::names] ne ""} {
		set i 0
		foreach name [rio::modes::names] {
			grid [prefs_radio $f.em[incr i] [rio::modes::label $name] ::edit_mode $name apply_editmode] \
				-row [incr r] -column 0 -sticky w -padx {12 0}
		}
	}
	grid [prefs_check $f.col "Column Editing (Ctrl+Shift+Drag)" ::col_on apply_column_edit] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
	# The core's setting, not a pref of ours (D132) — adopted, then written only here. One
	# door on purpose: a menu is for fast switches (D85) and this is set-once policy.
	adopt_autosave_settings
	grid [prefs_check $f.as "Keep recovery files for unsaved changes" ::autosave_on autosave_set] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
	grid [prefs_hint $f.ashint [autosave_hint]] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
}

# Agent category: the provider picker (enumerated from the core like the theme
# radios, so an installed provider appears), a muted hint when only the echo stub is
# present, the two agent-edit toggles, and the doors to the agent's instructions and its
# command allow-list (Agent Prompts…, D70/D79; Allowed commands…, D84).
#
# Everything here is RIO's — the concepts rio owns, whichever provider is running. What
# belongs to one particular provider (its key, its endpoint, its model) is that
# provider's own window, under the Extensions menu (D130).
proc prefs_fill_agent {f} {
	agent_providers_refresh
	set r 0
	grid [prefs_label $f.pl "Agent"] -row [incr r] -column 0 -sticky w
	set i 0 ; set have_real 0
	foreach p $::agent_providers {
		if {[dict get $p name] ne "echo"} { set have_real 1 }
		grid [prefs_radio $f.p[incr i] [provider_radio_label $p] \
			::agent_provider [dict get $p name] apply_provider] \
			-row [incr r] -column 0 -sticky w -padx {12 0}
	}
	# Echo is only a stub: with no real provider installed the picker is a single
	# offline option, so point the way to one — Extensions… is a button in this very
	# window. Guidance, not a control, so it's muted (prefs_hint / D68); once a real
	# provider is installed the pane is self-explanatory and the hint drops away.
	if {!$have_real} {
		grid [prefs_hint $f.hint "Echo is a built-in stub. Install Claude or an OpenAI-compatible provider from Extensions… to use a real model."] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	}
	# The mode: three exclusive states over the core's two flags (D102), the same
	# ::agent_mode_ui and the same writer the chat header's control and the Settings
	# cascade use — three doors, one answer.
	grid [prefs_label $f.ml "Mode"] -row [incr r] -column 0 -sticky w -pady {8 1}
	foreach {v lbl} {plan "Plan — read and plan, change nothing until you approve a plan" \
			review "Review each edit" auto "Auto-accept edits"} {
		grid [prefs_radio $f.m$v $lbl ::agent_mode_ui $v agent_mode_set] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady 1
	}
	grid [prefs_check $f.cc "Compare complex edits" ::agent_compare_complex {}] -row [incr r] -column 0 -sticky w -pady 1
	# The editor's one AI entry (D113). On by default, yet only ever seen with a real
	# provider selected — so someone who never installs one never meets it, and someone
	# who does can still keep their context menu to plain editing.
	grid [prefs_check $f.selmenu "Show “Change with Agent…” in the editor's context menu" \
		::agent_selection_menu prefs_save] -row [incr r] -column 0 -sticky w -pady {8 1}
	grid [prefs_hint $f.selhint "Shown only while a provider other than Echo is selected. It asks the agent to change the selected text and nothing else."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	# What a provider lets you configure is the PROVIDER's business (D106), and since
	# D130 it is configured in the PROVIDER's own window, reached from the Extensions
	# menu — so this pane no longer grows a pair of buttons per installed provider, and
	# rio's own agent settings above are no longer interleaved with somebody else's.
	# A muted pointer rather than a second door: guidance, not a control (D68).
	grid [prefs_hint $f.provhint "Each provider's own settings — its API key, and whatever else it declares, such as its endpoint and model — live in that provider's window, under the Extensions menu."] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
	# The agent's instructions (system / project / per-provider prompts, D70/D79) are
	# the third leg of its config alongside provider + key. This pane is their ONLY home
	# now — the Settings menu keeps just the provider picker and the two quick toggles,
	# so all of the agent's heavier configuration gathers here (jka, 2026-09-09).
	grid [prefs_button $f.prompts "Agent Prompts…" agent_prompts_dialog] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	# The command allow-list (D84) — the standing-approval companion to the gate. Its
	# only door, beside the prompts button just above.
	grid [prefs_button $f.allow "Allowed commands…" agent_allow_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Extensions category (D107): where the repositories are configured and where the
# one durable decision about them lives — whether rio looks for new versions when
# it starts. D85 puts it here rather than in the Extensions window: that window is
# a browsing surface, this is the config home. The two buttons are doors to the
# surfaces themselves, so the pane is not a dead end.
proc prefs_fill_extensions {f} {
	set r 0
	grid [prefs_check $f.chk "Check for extension updates at start-up" \
		::ext_check_updates ext_check_pref_save] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_hint $f.hint "Off by default: rio asks its core to fetch from your repositories only when you tell it to. Updates are never installed automatically, and an update comes from the repository an extension was installed from — a same-named extension elsewhere is a different thing until you say otherwise."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	grid [prefs_check $f.unver "Use repositories rio can't check" \
		::repo_allow_unverified ext_check_pref_save] -row [incr r] -column 0 -sticky w -pady {6 1}
	grid [prefs_hint $f.unverhint "A repository can publish a signing key, and rio checks it by running ssh-keygen on the core's host (D118). Where that isn't installed, a repository whose key rio trusts is refused rather than used unchecked. Turn this on to use it anyway: it then lists and installs marked \"unverified\", never \"signed\". A signature that fails, a key that changed, or a file that doesn't match is refused either way."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	# "Browse…" here for the same reason the menu entry says it: this button sits
	# INSIDE the Extensions category, so "Extensions…" would name the noun twice.
	# The window-level button beside Close is not under that heading and keeps the
	# window's own name.
	grid [prefs_button $f.ext "Browse…" extensions_window] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	grid [prefs_button $f.repos "Repositories…" extw_sources_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
	grid [prefs_button $f.keys "Repository signing keys…" repo_keys_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Network category (D114): how the core's https connections are verified — for the agent
# and extension repositories alike, so neither of their panes owns it. The one security
# trade-off (D110), off by default; it lives here, not in Settings: a fast switch it is
# not. And the certificates accepted one by one (D111), which also apply to every https
# connection the core makes.
proc prefs_fill_network {f} {
	adopt_tls_settings
	set r 0
	grid [prefs_check $f.tls "Allow https without host-name checks (tcltls older than 1.8)" \
		::tls_unchecked tls_unchecked_set] -row [incr r] -column 0 -sticky w -pady 1
	grid [prefs_hint $f.hint [tls_unchecked_hint]] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	grid [prefs_button $f.certs "Accepted certificates…" certs_dialog] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
}

# Keyboard category: app shortcuts keep their own recorder (D23) — reached, not
# reimplemented, from here.
proc prefs_fill_keyboard {f} {
	grid [prefs_label $f.blurb "App shortcuts are edited in their own recorder — click a\ncommand, then press the keys. They always win over the editing mode's keys."] \
		-row 0 -column 0 -sticky w -pady {0 8}
	grid [prefs_button $f.edit "Edit Keyboard Shortcuts…" keybindings_dialog] -row 1 -column 0 -sticky w
}

# Raise the body frame for the selected category.
proc prefs_show_cat {w} {
	set sel [$w.cats curselection]
	if {$sel eq ""} return
	raise $w.body.[string tolower [$w.cats get $sel]]
}

proc preferences_window {} {
	set w .prefs
	if {[winfo exists $w]} { wm deiconify $w ; raise $w ; focus $w.cats ; return }
	toplevel $w
	wm title $w "Preferences"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Left: the category list. Right: one body frame per category, stacked at the same
	# cell and raised on selection (a tab-like switch without a notebook widget).
	listbox $w.cats -width 12 -height 8 -exportselection 0 -font RioUIFont \
		-activestyle none -highlightthickness 0 -borderwidth 1 -relief solid \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg]
	foreach cat {View Editor Agent Extensions Network Keyboard} { $w.cats insert end $cat }
	bind $w.cats <<ListboxSelect>> [list prefs_show_cat $w]

	frame $w.body -background [dict get $c ui.bg]
	foreach cat {view editor agent extensions network keyboard} {
		frame $w.body.$cat -background [dict get $c ui.bg]
		grid $w.body.$cat -row 0 -column 0 -sticky nsew
	}
	prefs_fill_view       $w.body.view
	prefs_fill_editor     $w.body.editor
	prefs_fill_agent      $w.body.agent
	prefs_fill_extensions $w.body.extensions
	prefs_fill_network    $w.body.network
	prefs_fill_keyboard   $w.body.keyboard

	# Extensions… mirrors the top-level Extensions menu, which it leads (D130): from here
	# you jump to the installer for the providers/modes/themes/syntax the categories
	# above pick from. Left of Close; a spacer column keeps them apart.
	frame $w.btns -background [dict get $c ui.bg]
	grid [prefs_button $w.btns.ext   "Extensions…" [list extensions_window]] -row 0 -column 0 -sticky w
	grid [prefs_button $w.btns.close "Close"       [list destroy $w]]         -row 0 -column 2 -sticky e
	grid columnconfigure $w.btns 1 -weight 1

	grid $w.cats -row 0 -column 0 -sticky ns   -padx {8 4} -pady 8
	grid $w.body -row 0 -column 1 -sticky nsew -padx {4 8} -pady 8
	grid $w.btns -row 1 -column 0 -columnspan 2 -sticky we -padx 8 -pady {0 8}
	grid columnconfigure $w 1 -weight 1
	grid rowconfigure    $w 0 -weight 1

	$w.cats selection set 0
	prefs_show_cat $w
	bind $w <Escape> [list destroy $w]
	focus $w.cats
}

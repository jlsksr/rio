# rio-gui/prefs.tcl — sessions, preferences and the Preferences window.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Read the core's autosave setting (D132). Read at attach, never written
# then: the policy is the core's. Silent on failure.
proc adopt_autosave_settings {} {
	set r [rio_call autosave.settings {}]
	if {![dict get $r ok]} return
	set ::autosave_on [dict get $r result enabled]
	set ::autosave_interval [dict get $r result interval]
}

# The autosave interval in words: "30 seconds", "minute", "5 minutes". Read
# from the core, so the hint holds no second copy of the number.
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

# The checkbox's command: write, then show what the core accepted. On a
# refusal the box goes back.
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

# Read the core's https switch (D114) and what its tcltls can check. Read at
# attach, never written then. Silent on failure.
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

# Preferences ▸ Network ▸ "Allow https without host-name checks" (D110,
# D114). The choice is the core's: write, then show what it stored. On a
# refusal the box goes back.
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

# The hint under that checkbox, and whether it matters on this core.
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
# Sessions and preferences (D31), by owner:
#
#   preferences   how the editor looks       the GUI: $XDG_CONFIG_HOME/rio/prefs.json
#   workspace     the open files, the tab,   the core: workspace.* ops, per
#                 the unfolded tree          project root (D30)
#
# - prefs.json is JSON data, parsed and never executed (D21).
# - Neither holds a secret.
# - Nothing is written before ::rio_started: boot must not save the defaults
#   over what it just loaded.
# ---------------------------------------------------------------------------
proc prefs_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio prefs.json]
}

# Read a whole UTF-8 file, always closing the channel. A leaked handle locks
# the file on Windows, and rio could then not rewrite it.
proc slurp_utf8 {path} {
	set f [open $path r]
	try {
		fconfigure $f -encoding utf-8
		return [::read $f]
	} finally {
		close $f
	}
}

# Load saved preferences over the defaults. A missing or corrupt file leaves
# the defaults. Unknown keys and invalid values are ignored.
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
	# The editor font override (D56), laid over the theme's font.
	if {[dict exists $d font_family]} { set ::editor_font_family [dict get $d font_family] }
	if {[dict exists $d font_size]} {
		set s [dict get $d font_size]
		if {[string is integer -strict $s] && $s >= 5 && $s <= 72} { set ::editor_font_size $s }
	}
	# The dock layout (D35): a saved `layout` object, or the older flat keys
	# (dock_side, dock_pane, chat_shown) migrated.
	if {[dict exists $d layout]} {
		set ::layout [rio::layout::boot [dict get $d layout]]
	} else {
		set ::layout [rio::layout::boot [rio::layout::migrate $d]]
	}
	if {[dict exists $d editmode]} { set ::edit_mode [dict get $d editmode] }
	# The last folder opened on a local core (D88); reopen_last_project opens it.
	if {[dict exists $d project]} { set ::last_project [dict get $d project] }
}

# Save the preferences. Every applier calls it (do_theme, apply_wrap,
# apply_layout, …), so any toggle is recorded. Scalars are flat strings; the
# dock layout is the nested `layout` object (D35).
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
		# The scalars without their closing brace, then `layout`, then a
		# brace, escaped so it does not end the catch body.
		set json "[string range $scalars 0 end-1],\"layout\":[rio::layout::json]\}"
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f $json ; close $f
	}
}

# Save the workspace: the open tabs' paths (a tab without a file is left
# out), the active tab, the unfolded directories (D89). The core keys it by
# the open project. `open` and `expanded` are newline-joined strings.
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

# Reopen the folder of the last launch (D88). The core keeps the open folder
# in memory only, so the GUI saves the path in prefs.json. During boot,
# before session_restore, and only if no project is open yet. Local cores
# only. A folder that is gone is skipped.
proc reopen_last_project {} {
	if {$::nav_root ne "" || $::core_remote} return
	# A local daemon may already have a project open: adopt that one.
	set root [dict get [rio_call project.get {}] result root]
	if {$root ne ""} { on_project_opened [dict create root $root] ; return }
	if {$::last_project eq ""} return
	if {![file isdirectory $::last_project]} {
		# The folder is gone: forget it (D89).
		set ::last_project ""
		return
	}
	open_folder $::last_project
}

# Restore the workspace: reopen each saved file and focus the saved tab. The
# core has dropped the files that are gone. Boot only, while ::rio_started is
# 0, so these opens save nothing.
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
	# The unfolded directories (D89). Only with a project open.
	if {$::nav_root ne ""} {
		set ::nav_expanded [dict create]
		foreach d [dict get $res expanded] { dict set ::nav_expanded $d 1 }
		if {[dict size $::nav_expanded]} { populate_nav }
	}
}

# ---------------------------------------------------------------------------
# The Preferences window (D58): every setting in one place.
# - It owns no state. A control uses the same global and the same applier as
#   its menu entry, so the two stay in step.
# - No Save or Cancel: a change applies at once.
# - Commands (Zoom, Split, Compare) are not preferences and stay in the menus.
# ---------------------------------------------------------------------------
# Themed controls, one line each. `args` passes extra options through.
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
# A muted hint line: help text must not look like a control (D68).
proc prefs_hint {w text {wrap 300}} {
	set c $::theme_colors
	label $w -text $text -anchor w -justify left -font RioUIFont -wraplength $wrap \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	return $w
}

# View: the View menu's toggles, the dock side, the theme, the font.
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
	# The theme button shows the current theme and opens the picker, as
	# View ▸ Theme… does (D92).
	grid [prefs_label $f.thl "Theme"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.theme "" theme_pick_dialog] -row [incr r] -column 0 -sticky w -padx {12 0}
	$f.theme configure -textvariable ::theme_choice_label -anchor w
	grid [prefs_label $f.fontl "Font"] -row [incr r] -column 0 -sticky w -pady {8 0}
	grid [prefs_button $f.font "Font…" editor_font_dialog] -row [incr r] -column 0 -sticky w -padx {12 0} -pady {0 2}
}

# Editor: the editing mode (from the registry), column editing, autosave.
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
	# Autosave is the core's setting (D132). This is its only control (D85).
	adopt_autosave_settings
	grid [prefs_check $f.as "Keep recovery files for unsaved changes" ::autosave_on autosave_set] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
	grid [prefs_hint $f.ashint [autosave_hint]] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
}

# Agent: the provider picker, the mode, the two edit toggles, Agent Prompts…
# (D70, D79) and Allowed commands… (D84). These are rio's settings. A
# provider's own (key, endpoint, model) are in its window (D130).
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
	# Only Echo: say where to get a real provider.
	if {!$have_real} {
		grid [prefs_hint $f.hint "Echo is a built-in stub. Install Claude or an OpenAI-compatible provider from Extensions… to use a real model."] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	}
	# The mode (D102): the same variable and writer as the chat header's control.
	grid [prefs_label $f.ml "Mode"] -row [incr r] -column 0 -sticky w -pady {8 1}
	foreach {v lbl} {plan "Plan — read and plan, change nothing until you approve a plan" \
			review "Review each edit" auto "Auto-accept edits"} {
		grid [prefs_radio $f.m$v $lbl ::agent_mode_ui $v agent_mode_set] \
			-row [incr r] -column 0 -sticky w -padx {12 0} -pady 1
	}
	grid [prefs_check $f.cc "Compare complex edits" ::agent_compare_complex {}] -row [incr r] -column 0 -sticky w -pady 1
	# The context menu's agent entry (D113). On by default; shown only with a
	# real provider.
	grid [prefs_check $f.selmenu "Show “Change with Agent…” in the editor's context menu" \
		::agent_selection_menu prefs_save] -row [incr r] -column 0 -sticky w -pady {8 1}
	grid [prefs_hint $f.selhint "Shown only while a provider other than Echo is selected. It asks the agent to change the selected text and nothing else."] \
		-row [incr r] -column 0 -sticky w -padx {12 0} -pady {2 1}
	# A pointer to the providers' own windows (D130): a hint, not a control.
	grid [prefs_hint $f.provhint "Each provider's own settings — its API key, and whatever else it declares, such as its endpoint and model — live in that provider's window, under the Extensions menu."] \
		-row [incr r] -column 0 -sticky w -pady {8 1}
	# The prompts (D70, D79) and the allow-list (D84): reached only from here.
	grid [prefs_button $f.prompts "Agent Prompts…" agent_prompts_dialog] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	grid [prefs_button $f.allow "Allowed commands…" agent_allow_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Extensions (D107): the update check at start-up, repositories rio cannot
# check, and buttons to the Extensions window, the repositories and the keys.
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
	# "Browse…", as in the menu: the category is already called Extensions.
	grid [prefs_button $f.ext "Browse…" extensions_window] \
		-row [incr r] -column 0 -sticky w -pady {8 2}
	grid [prefs_button $f.repos "Repositories…" extw_sources_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
	grid [prefs_button $f.keys "Repository signing keys…" repo_keys_dialog] \
		-row [incr r] -column 0 -sticky w -pady {2 2}
}

# Network (D114): how the core's https connections are verified, for the
# agent and the repositories alike. The host-name switch (D110) and the
# accepted certificates (D111).
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

# Keyboard: a button to the shortcut recorder (D23).
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

	# Left: the categories. Right: one frame per category in the same cell;
	# the selected one is raised.
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

	# Extensions… opens the installer (D130). Left of Close.
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

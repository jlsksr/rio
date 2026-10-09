# rio-gui/keymap.tcl — the keymap and the shortcuts editor.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The keymap (D23): one table, command -> {chord action label}. The editor's
# shortcuts and the menus' accelerator labels both come from it.
#
# - A chord is Tk event syntax without the <>: Control-s, Control-Shift-Tab,
#   F3. A capital letter implies Shift: Control-S is Ctrl+Shift+S.
# - keys.json in the config dir (D21) overrides chords:
#     {"save": "Control-F2", "quit": ""}        "" unbinds
# - An override changes only the chord. `action` is what the key does;
#   `label` is the name in the shortcuts editor.
# - A new command is one line here.
# ---------------------------------------------------------------------------
# The table as written. ::keymap_default, below, is the table for this
# platform, and is what everything else reads.
set ::keymap_base {
	new            {Control-n            do_new                                                        "New tab"}
	open           {Control-o            open_dialog                                                   "Open file…"}
	open-folder    {Control-O            open_folder_dialog                                            "Open folder…"}
	save           {Control-s            do_save                                                       "Save"}
	save-as        {Control-S            save_as_dialog                                                "Save As…"}
	close-tab      {Control-w            do_close                                                      "Close tab"}
	quit           {Control-q            do_quit                                                       "Quit"}
	undo           {Control-z            do_undo                                                       "Undo"}
	redo           {Control-Z            do_redo                                                       "Redo"}
	redo-alt       {Control-y            do_redo                                                        "Redo (alternate)"}
	find           {Control-f            {find_open 0}                                                 "Find…"}
	replace        {Control-h            {find_open 1}                                                 "Replace…"}
	find-next      {F3                   find_next                                                     "Find next"}
	find-prev      {Shift-F3             find_prev                                                     "Find previous"}
	search         {Control-F            search_open                                                   "Search…"}
	next-tab       {Control-Tab          {cycle 1}                                                     "Next tab"}
	prev-tab       {Control-Shift-Tab    {cycle -1}                                                    "Previous tab"}
	show-files     {Control-E            {panel_key files}                                             "Toggle files pane"}
	show-git       {Control-G            {panel_key git}                                               "Toggle git pane"}
	toggle-wrap    {Control-W            {set ::wrap_lines [expr {!$::wrap_lines}] ; apply_wrap}        "Toggle line wrap"}
	toggle-linenums {Control-l           {set ::line_numbers [expr {!$::line_numbers}] ; apply_line_numbers} "Toggle line numbers"}
	toggle-chat    {Control-A            {panel_key chat}                                              "Toggle agent pane"}
	split-editor   {Control-backslash    toggle_split                                                  "Toggle editor split"}
	move-tab-other {Control-bracketright move_tab_other                                                "Move tab to other group"}
	preferences    {{}                   preferences_window                                            "Preferences…"}
	help           {F1                   help_window                                                   "Help contents…"}
}
# On a Mac, Control in the table above is read as Command (D136). The
# exceptions:
#   quit      unbound: the application menu's ⌘Q already calls do_quit (D134)
#   replace   ⌥⌘F: ⌘H is Hide. Written with the keysym Tk delivers: ⌥F
#             arrives as ƒ, keysym `function`. key_glyph shows it as F.
#   next-tab, prev-tab   stay on Control: ⌘Tab switches applications
# (No comments inside the braces: there `;#` is data.)
set ::keymap_aqua {
	quit     {}
	replace  Option-Command-function
	next-tab Control-Tab
	prev-tab Control-Shift-Tab
}
# The defaults for windowing system `ws`. No Tk state, so the Mac's table can
# be tested on any host.
proc keymap_for_platform {map ws} {
	if {$ws ne "aqua"} { return $map }
	dict for {cmd spec} $map {
		set chord [lindex $spec 0]
		if {[dict exists $::keymap_aqua $cmd]} {
			set chord [dict get $::keymap_aqua $cmd]
		} elseif {[string match Control-* $chord]} {
			set chord Command-[string range $chord 8 end]
		}
		dict set map $cmd [lreplace $spec 0 0 $chord]
	}
	return $map
}
set ::keymap_default [keymap_for_platform $::keymap_base [tk windowingsystem]] ;# the defaults in force here
set ::keymap     $::keymap_default ;# resolved map (defaults + user overrides); keymap_resolve fills it
set ::keymap_bad {}                ;# entries keys.json got wrong, for one post-startup notice
set ::keymap_live_chords {}        ;# chords currently bound on the group widgets (to clear on a live remap)
# Commands bound on the main window too, so they fire wherever focus is: a
# pane's chord must also close it from inside that pane; Search opens from
# any pane.
set ::keymap_window {show-files show-git toggle-chat search}
set ::keymap_window_chords {}      ;# their chords bound on `.` now

proc keys_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio keys.json]
}

# Is `chord` usable? "" is: it unbinds. Tk's `bind` accepts almost anything,
# so the check is on the shape: every part before the key must be a known
# modifier. A misspelt key still binds, and never fires.
proc keymap_valid {chord} {
	if {$chord eq ""} { return 1 }
	set mods {Control Ctrl Shift Alt Meta Command Option \
		Mod1 Mod2 Mod3 Mod4 Mod5 Lock Extended}
	set parts [split $chord -]
	foreach m [lrange $parts 0 end-1] { if {$m ni $mods} { return 0 } }
	return [expr {[lindex $parts end] ne ""}]
}

# ::keymap = the defaults with keys.json's overrides. A corrupt file, an
# unknown command or a bad chord is ignored and noted in ::keymap_bad, for
# one notice at startup.
proc keymap_resolve {} {
	set ::keymap $::keymap_default
	set ::keymap_bad {}
	set path [keys_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {set over [json::json2dict [slurp_utf8 $path]]}]} {
		lappend ::keymap_bad "keys.json is not valid JSON — ignored" ; return
	}
	dict for {cmd chord} $over {
		if {![dict exists $::keymap_default $cmd]} {
			lappend ::keymap_bad "unknown command \"$cmd\"" ; continue
		}
		if {![keymap_valid $chord]} {
			lappend ::keymap_bad "\"$cmd\": invalid chord \"$chord\"" ; continue
		}
		# Replace only the chord; keep the command's action and label (set in code).
		dict set ::keymap $cmd [lreplace [dict get $::keymap $cmd] 0 0 $chord]
	}
}

# The chord bound to `cmd` in the resolved keymap ("" if unbound / unknown).
proc key_chord {cmd} {
	if {![dict exists $::keymap $cmd]} { return "" }
	return [lindex [dict get $::keymap $cmd] 0]
}

# The human name of `cmd` (the shortcuts editor's row label); falls back to the id.
proc key_label {cmd} {
	if {![dict exists $::keymap_default $cmd]} { return $cmd }
	set l [lindex [dict get $::keymap_default $cmd] 2]
	return [expr {$l eq "" ? $cmd : $l}]
}

# The accelerator label for `cmd`, from its chord; "" when unbound.
proc key_accel {cmd} { return [chord_label [key_chord $cmd]] }

# A chord as a label:
#   Control-Shift-e -> Ctrl+Shift+E    Control-backslash -> Ctrl+\
#   Control-S -> Ctrl+Shift+S          Command-s -> Cmd+S
# `ws` is the windowing system: on a Mac Mod1 is Command and Mod2 is Option
# (D136). The modifier order is Ctrl Alt Opt Shift Cmd, the Mac menus' order.
proc chord_label {chord {ws ""}} {
	if {$chord eq ""} { return "" }
	if {$ws eq ""} { set ws [tk windowingsystem] }
	set mac [expr {$ws eq "aqua"}]
	set parts [split $chord -]
	set key   [lindex $parts end]
	set out {} ; set shift 0
	foreach m [lrange $parts 0 end-1] {
		switch -- $m {
			Control - Ctrl    { lappend out Ctrl }
			Shift             { set shift 1 }
			Command           { lappend out Cmd }
			Option            { lappend out Opt }
			Mod1              { lappend out [expr {$mac ? "Cmd" : "Alt"}] }
			Mod2              { lappend out [expr {$mac ? "Opt" : "Mod2"}] }
			Alt - Meta        { lappend out Alt }
			default           { lappend out $m }
		}
	}
	if {[string length $key] == 1 && [string is upper $key]} { set shift 1 }
	if {$shift} { lappend out Shift }
	set order {}
	foreach want {Ctrl Alt Opt Shift Cmd} { if {$want in $out} { lappend order $want } }
	lappend order [key_glyph $key]
	return [join $order +]
}

# Display glyph for a single key: letters upper-cased, common keysyms to their symbol.
proc key_glyph {key} {
	set map [dict create \
		backslash "\\" bracketright "]" bracketleft "\[" slash "/" grave "`" \
		semicolon ";" comma "," period "." minus "-" equal "=" space "Space"  function F]   ;# ƒ: what ⌥F types on a Mac, so an Opt+Cmd+F chord's keysym (D136)
	if {[dict exists $map $key]}        { return [dict get $map $key] }
	if {[string length $key] == 1}      { return [string toupper $key] }
	return $key   ;# Tab, Escape, Return, F5, … shown as-is
}

# Bind the keymap on a group's text widget, with `break`, so Tk's own class
# bindings (Ctrl+O, Ctrl+Z, …) do not fire too.
proc editor_bindings {w} {
	dict for {cmd spec} $::keymap {
		lassign $spec chord action
		if {$chord eq ""} continue   ;# a deliberately unbound command
		catch { bind $w <$chord> "$action ; break" }
	}
}

# Zoom (D56): Ctrl+wheel and Ctrl +/- resize the editor font; Ctrl+0 resets.
# Fixed keys, not keymap entries. Bound on the editor and on its gutter.
# Both wheel idioms: X11's Button-4/5 and MouseWheel elsewhere.
proc editor_zoom_bindings {w} {
	bind $w <Control-MouseWheel> {editor_zoom [expr {%D > 0 ? 1 : -1}] ; break}
	bind $w <Control-Button-4>   {editor_zoom 1 ; break}
	bind $w <Control-Button-5>   {editor_zoom -1 ; break}
	bind $w <Control-plus>       {editor_zoom 1 ; break}
	bind $w <Control-equal>      {editor_zoom 1 ; break}   ;# Ctrl+= so no Shift is needed
	bind $w <Control-KP_Add>     {editor_zoom 1 ; break}
	bind $w <Control-minus>      {editor_zoom -1 ; break}
	bind $w <Control-KP_Subtract> {editor_zoom -1 ; break}
	bind $w <Control-Key-0>      {editor_zoom_reset ; break}
	bind $w <Control-KP_0>       {editor_zoom_reset ; break}
	# A Mac zooms with Command too (D136).
	if {$::primary_mod ne "Control"} {
		foreach {seq script} {
			MouseWheel {editor_zoom [expr {%D > 0 ? 1 : -1}] ; break}
			plus {editor_zoom 1 ; break}     equal {editor_zoom 1 ; break}
			minus {editor_zoom -1 ; break}   Key-0 {editor_zoom_reset ; break}
		} { bind $w <$::primary_mod-$seq> $script }
	}
}

# The non-empty chords in the resolved keymap.
proc keymap_chords {} {
	set out {}
	dict for {cmd spec} $::keymap { set c [lindex $spec 0] ; if {$c ne ""} { lappend out $c } }
	return $out
}

# Apply the keymap to every editor group: clear the chords bound last time
# (::keymap_live_chords), then bind the current ones.
proc keymap_rebind_all {} {
	foreach g $::groups {
		set w [gget $g path]
		foreach c $::keymap_live_chords { catch {bind $w <$c> ""} }
		editor_bindings $w
	}
	set ::keymap_live_chords [keymap_chords]
	window_bindings
}

# Bind ::keymap_window's chords on `.`, the tag every widget in the main
# window carries. The editor's own binding breaks first, so no double fire.
proc window_bindings {} {
	foreach c $::keymap_window_chords { catch {bind . <$c> ""} }
	set ::keymap_window_chords {}
	foreach cmd $::keymap_window {
		lassign [dict get $::keymap $cmd] chord action
		if {$chord eq ""} continue
		if {![catch {bind . <$chord> $action}]} { lappend ::keymap_window_chords $chord }
	}
}

# Set every menu accelerator from the keymap. Entries are found by label.
proc keymap_refresh_menus {} {
	.m.file entryconfigure "New"          -accelerator [key_accel new]
	.m.file entryconfigure "Open…"        -accelerator [key_accel open]
	.m.file entryconfigure "Open Folder…" -accelerator [key_accel open-folder]
	.m.file entryconfigure "Save"         -accelerator [key_accel save]
	.m.file entryconfigure "Save As…"     -accelerator [key_accel save-as]
	.m.file entryconfigure "Close Tab"    -accelerator [key_accel close-tab]
	.m.file entryconfigure "Quit"         -accelerator [key_accel quit]
	.m.edit entryconfigure "Undo"          -accelerator [key_accel undo]
	.m.edit entryconfigure "Redo"          -accelerator [key_accel redo]
	.m.find entryconfigure "Find…"         -accelerator [key_accel find]
	.m.find entryconfigure "Replace…"      -accelerator [key_accel replace]
	.m.find entryconfigure "Find Next"     -accelerator [key_accel find-next]
	.m.find entryconfigure "Find Previous" -accelerator [key_accel find-prev]
	.m.find entryconfigure "Search…"       -accelerator [key_accel search]
	.m.view entryconfigure "Files"        -accelerator [key_accel show-files]
	.m.view entryconfigure "Git"          -accelerator [key_accel show-git]
	.m.view entryconfigure "Agent"        -accelerator [key_accel toggle-chat]
	.m.view entryconfigure "Search"       -accelerator [key_accel search]
	.m.view entryconfigure "Wrap Lines"   -accelerator [key_accel toggle-wrap]
	.m.view.layout entryconfigure "Split Editor" -accelerator [key_accel split-editor]
	.m.view.layout entryconfigure "Move Tab to Other Group" -accelerator [key_accel move-tab-other]
	.m.settings entryconfigure "Preferences…" -accelerator [key_accel preferences]
	.m.help entryconfigure "Contents…"        -accelerator [key_accel help]
}

# After keys.json changed: read it again, rebind, relabel the menus.
proc keymap_apply_live {} {
	keymap_resolve
	keymap_rebind_all
	keymap_refresh_menus
}

# ---- Pure helpers for the shortcuts editor (unit-tested; no widgets) --------------

# A key event (keysym and state, from %K and %s) as a chord, or "" if it is
# no shortcut: a lone modifier, or a lone printable key, which would hijack
# typing. F5 alone is fine.
#   s, Control|Shift -> Control-Shift-s
# On a Mac (D136) state 0x8 is Command and 0x10 is Option.
proc event_to_chord {keysym state {ws ""}} {
	if {$ws eq ""} { set ws [tk windowingsystem] }
	if {[string match *_L $keysym] || [string match *_R $keysym] \
		|| $keysym in {Caps_Lock Num_Lock Shift Control Alt Meta ISO_Level3_Shift}} { return "" }
	set mods {}
	if {$state & 0x4} { lappend mods Control }
	if {$ws eq "aqua"} {
		if {$state & 0x10} { lappend mods Option } ;# Mod2
	} elseif {$state & 0x8} { lappend mods Alt }   ;# Mod1
	if {$state & 0x1} { lappend mods Shift }
	if {$ws eq "aqua" && ($state & 0x8)} { lappend mods Command } ;# Mod1
	set key $keysym
	if {[string length $key] == 1 && [string is alpha $key]} { set key [string tolower $key] }
	if {[llength $mods] == 0 && [string length $key] == 1} { return "" }  ;# bare printable: refuse
	return [join [concat $mods [list $key]] -]
}

# The other command in `chords` (command -> chord) that uses `chord`, or "".
proc keys_conflict {chords cmd chord} {
	if {$chord eq ""} { return "" }
	dict for {c ch} $chords {
		if {$c ne $cmd && $ch eq $chord} { return $c }
	}
	return ""
}

# The overrides to save: only the commands whose chord differs from the
# default, "" for an unbound one.
proc keymap_overrides {chords} {
	set out {}
	dict for {cmd chord} $chords {
		set dflt [lindex [dict get $::keymap_default $cmd] 0]
		if {$chord ne $dflt} { dict set out $cmd $chord }
	}
	return $out
}

# Write the overrides to keys.json; an empty dict deletes the file. Returns
# 1 on success.
proc keys_save {overrides} {
	set path [keys_path]
	if {$path eq ""} { return 0 }
	if {[dict size $overrides] == 0} { catch {file delete $path} ; return 1 }
	if {[catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::obj $overrides] ; close $f
	}]} { return 0 }
	return 1
}

# ---------------------------------------------------------------------------
# The shortcuts editor (D23): a modal list of every command and its chord.
# Click, then press the keys; or clear, or reset. Edits go to a working copy,
# ::keys_work. Cancel drops it; Save writes keys.json and applies it at once.
# ---------------------------------------------------------------------------
proc keys_refresh_buttons {} {
	dict for {cmd chord} $::keys_work {
		if {![winfo exists .keys.body.k$cmd]} continue
		set lbl [chord_label $chord]
		.keys.body.k$cmd configure -text [expr {$lbl eq "" ? "(unbound)" : $lbl}]
	}
}
proc keys_status {msg} { catch {.keys.status configure -text $msg} }

# Begin recording a chord for `cmd`. Any capture in progress is cancelled first; focus
# moves to the toplevel so keypresses land on our <KeyPress> handler, not a button.
proc keys_capture {cmd} {
	if {$::keys_capturing ne ""} { keys_capture_cancel }
	set ::keys_capturing $cmd
	.keys.body.k$cmd configure -text "Press keys…"
	keys_status "Recording “[key_label $cmd]” — press a shortcut, or Esc to cancel."
	focus .keys
}
proc keys_capture_cancel {} {
	if {$::keys_capturing eq ""} return
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status ""
}

# A key arrived while recording: ignore unusable keys (bare modifier / lone printable) and
# conflicts, keep recording; otherwise set the chord and stop.
proc keys_on_key {keysym state} {
	if {$::keys_capturing eq ""} return
	set chord [event_to_chord $keysym $state]
	if {$chord eq ""} {
		keys_status "That key can’t be a shortcut on its own — add Ctrl / Alt / Shift."
		return
	}
	set cmd $::keys_capturing
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "[chord_label $chord] is already “[key_label $other]” — clear that first."
		return
	}
	dict set ::keys_work $cmd $chord
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status "Set “[key_label $cmd]” to [chord_label $chord]. Save to apply."
}
proc keys_clear {cmd} { dict set ::keys_work $cmd "" ; keys_refresh_buttons ; keys_status "" }
# Restore one command to its shipped default chord (the per-row counterpart of Reset all).
# We note if the restored chord now duplicates another command's, but still apply it — it's
# a deliberate "put it back" and the user can sort out the collision.
proc keys_default {cmd} {
	set chord [lindex [dict get $::keymap_default $cmd] 0]
	dict set ::keys_work $cmd $chord
	keys_refresh_buttons
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord] — now also on “[key_label $other]”."
	} else {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord]."
	}
}
proc keys_reset_all {} {
	set ::keys_work {}
	dict for {cmd spec} $::keymap_default { dict set ::keys_work $cmd [lindex $spec 0] }
	keys_refresh_buttons
	keys_status "Reset to defaults — Save to apply."
}
proc keys_dialog_save {} {
	keys_save [keymap_overrides $::keys_work]
	keymap_apply_live         ;# re-read the file and push new bindings + menu labels live
	destroy .keys
}

proc keybindings_dialog {} {
	set w .keys
	destroy $w
	toplevel $w
	wm title $w "Keyboard Shortcuts"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	set ::keys_capturing ""
	set ::keys_work {}
	dict for {cmd spec} $::keymap { dict set ::keys_work $cmd [lindex $spec 0] }

	label $w.hint -anchor w -font RioUIFont -justify left \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text "Click a shortcut, then press the keys you want. Clear unbinds; Default restores the original.\nThese app shortcuts always win over the editing mode's keys (Settings ▸ Editing Mode)."
	grid $w.hint -row 0 -column 0 -sticky we -padx 8 -pady {8 4}

	frame $w.body -background [dict get $c ui.bg]
	set r 0
	dict for {cmd spec} $::keymap_default {
		label $w.body.l$cmd -text [key_label $cmd] -anchor w -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $w.body.k$cmd -width 20 -font RioUIFont -command [list keys_capture $cmd]
		button $w.body.c$cmd -text "Clear"   -font RioUIFont -command [list keys_clear $cmd]
		button $w.body.d$cmd -text "Default" -font RioUIFont -command [list keys_default $cmd]
		grid $w.body.l$cmd -row $r -column 0 -sticky w  -padx {2 12} -pady 1
		grid $w.body.k$cmd -row $r -column 1 -sticky we -padx 2      -pady 1
		grid $w.body.c$cmd -row $r -column 2 -sticky w  -padx {2 2}  -pady 1
		grid $w.body.d$cmd -row $r -column 3 -sticky w  -padx {2 2}  -pady 1
		incr r
	}
	grid $w.body -row 1 -column 0 -sticky nwe -padx 8

	label $w.status -anchor w -font RioUIFont -text "" \
		-background [dict get $c ui.bg] -foreground [dict get $c accent]
	grid $w.status -row 2 -column 0 -sticky we -padx 8 -pady {4 2}

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.reset  -text "Reset all to defaults" -font RioUIFont -command keys_reset_all
	button $w.btns.cancel -text "Cancel" -font RioUIFont -command {destroy .keys}
	button $w.btns.save   -text "Save"   -font RioUIFont -command keys_dialog_save
	pack $w.btns.reset -side left
	pack $w.btns.save $w.btns.cancel -side right -padx 3
	grid $w.btns -row 3 -column 0 -sticky we -padx 5 -pady {2 8}

	# Capture keys only while recording; otherwise let them drive normal focus/buttons.
	bind $w <KeyPress> {if {$::keys_capturing ne ""} { keys_on_key %K %s ; break }}
	bind $w <Escape>   {if {$::keys_capturing ne ""} { keys_capture_cancel } else { destroy .keys }}
	keys_refresh_buttons
	catch {grab $w}
	focus $w
	tkwait window $w
}

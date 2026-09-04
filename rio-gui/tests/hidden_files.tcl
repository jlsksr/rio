#!/usr/bin/env wish
#
# Headless hidden-files test for rio-gui (AGENTS.md D62). The Files pane hides dotfile /
# hidden entries by default (like `ls`), with a View ▸ Show Hidden Files toggle (also in the
# Preferences window) to reveal them. Checks: dotfiles absent by default while regular
# entries show; the toggle reveals `.git/` and `.hidden` and hiding restores; the setting
# survives prefs.json; and the menu + Preferences doors drive the SAME global. Needs a
# DISPLAY and a throwaway project tree on disk (the pane lists it over the core's fs.list).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/hidden_files.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII (if any) and the GUI's glyphs agree. The guard every entry point carries (D54).
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
set ::connect_to "127.0.0.1:$::port"
set argv {}
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}
proc has {label name yes} {
	ok $label [expr {[lsearch -exact [nav_labels] $name] >= 0}] $yes
}
# The pane is a read-only rl_* text widget: each row is "<flag-gutter:2><glyph> <label>",
# so a label is the row text past the 4-char prefix (smoke.tcl's helper).
proc nav_labels {} {
	set b .pfiles.well.body
	set out {}
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set L [expr {$i + 1}]
		lappend out [string range [$b get "$L.0" "$L.0 lineend"] 4 end]
	}
	return $out
}

# A throwaway tree: two visible entries (sub/, zeta.txt) and two hidden ones (.git/, .hidden).
set tf [file tempfile tpath] ; close $tf
set proj [file join [file dirname $tpath] riogui-hidden-[clock clicks]]
file mkdir [file join $proj sub]
file mkdir [file join $proj .git]
set zf [open [file join $proj zeta.txt] w] ; puts -nonewline $zf "ZETA\n" ; close $zf
set hf [open [file join $proj .hidden]  w] ; puts -nonewline $hf "H\n"    ; close $hf

open_folder $proj

# --- default: dotfiles hidden, regular entries shown ---------------------------------
ok  "default: show_hidden off"   $::show_hidden 0
has "default: zeta.txt shown"    zeta.txt 1
has "default: sub/ shown"        sub/     1
has "default: .hidden hidden"    .hidden  0
has "default: .git/ hidden"      .git/    0

# --- toggle on (via the applier the doors call): dotfiles appear ----------------------
set ::show_hidden 1 ; apply_show_hidden
has "shown: .hidden appears"     .hidden  1
has "shown: .git/ appears"       .git/    1
has "shown: zeta.txt still there" zeta.txt 1

# --- toggle off: dotfiles hidden again ------------------------------------------------
set ::show_hidden 0 ; apply_show_hidden
has "hidden again: .hidden gone" .hidden  0
has "hidden again: zeta.txt kept" zeta.txt 1

# --- persistence through prefs.json --------------------------------------------------
set ::show_hidden 1 ; prefs_save
set ::show_hidden 0 ; prefs_load
ok "persist: reloaded as on"     $::show_hidden 1
set ::show_hidden 0 ; prefs_save   ;# restore the default for a clean sandbox

# --- two doors on one global: the View menu and the Preferences window ---------------
ok "menu: toggle is a checkbutton" [.m.view type "Show Hidden Files"] checkbutton
ok "menu: drives the global"     [.m.view entrycget "Show Hidden Files" -variable] ::show_hidden
preferences_window
ok "prefs: control exists"       [winfo exists .prefs.body.view.hidden] 1
ok "prefs: same var as menu"     [.prefs.body.view.hidden cget -variable] \
                                 [.m.view entrycget "Show Hidden Files" -variable]
destroy .prefs

# --- third door: the pane-header glyph button ----------------------------------------
ok "button: exists in files header" [winfo exists .pfiles.hdr.hidden] 1
ok "button: click wired to toggle"  [bind .pfiles.hdr.hidden <Button-1>] nav_toggle_hidden
set ::show_hidden 0 ; nav_hidden_glyph
ok "button: hollow glyph when off"  [.pfiles.hdr.hidden cget -text] ◌
nav_toggle_hidden                    ;# a real click flips the global + repaints + reglyphs
ok "button: toggles the global on"  $::show_hidden 1
ok "button: filled glyph when on"   [.pfiles.hdr.hidden cget -text] ◉
has "button: reveals .hidden"       .hidden 1
nav_toggle_hidden
ok "button: toggles back off"       $::show_hidden 0
has "button: hides .hidden again"   .hidden 0

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

#!/usr/bin/env wish
#
# Headless test for the Preferences window (AGENTS.md D58). The window owns no state:
# each control drives the SAME global its menu twin binds and calls the SAME applier, so
# it is live-apply and the two doors stay in sync for free. Checks that the window opens
# with its four categories, that toggling a control there flips the global AND matches
# the menu entry's -variable (the two-door sync), that changing the tab layout re-flows
# the strip, that the category switch selects, that opening twice is safe, and that the
# theme/mode radios are enumerated from the core/registry.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/prefs_window.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows); this file's own
# non-ASCII expectations (the … glyphs, theme labels) then arrive mojibake. Re-source
# under UTF-8 — the same guard every entry point carries; a test file is one too. No-op
# where the system encoding is already UTF-8.
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
# A fresh core buffer, registered in group 0 under a chosen display name.
proc mkbuf {name} {
	set id [dict get [rio_result buffer.new {}] buffer]
	register_buffer $id "/proj/$name" {} 0
	return $id
}

# --- the window opens with its four categories ------------------------------------
preferences_window
update idletasks
ok "window exists"               [winfo exists .prefs]                 1
ok "four categories"             [.prefs.cats size]                    4
ok "view body exists"            [winfo exists .prefs.body.view]       1
ok "editor body exists"          [winfo exists .prefs.body.editor]     1
ok "agent body exists"           [winfo exists .prefs.body.agent]      1
ok "keyboard body exists"        [winfo exists .prefs.body.keyboard]   1

# --- two-door sync: the window control binds the SAME global the menu entry does ---
ok "wrap: same var as menu"      [.prefs.body.view.wrap cget -variable] \
                                 [.m.view entrycget "Wrap Lines" -variable]
ok "tabs: same var as menu"      [.prefs.body.view.mtab cget -variable] \
                                 [.m.view entrycget "Multi-Line Tabs" -variable]

# --- toggling a control in the window flips the live global (and so the editor) ----
set w0 $::wrap_lines
.prefs.body.view.wrap invoke
ok "wrap: window toggles global" [expr {$::wrap_lines != $w0}]         1
.prefs.body.view.wrap invoke
ok "wrap: toggles back"          $::wrap_lines                         $w0

# --- changing the tab layout from the window re-flows the strip --------------------
set a [mkbuf pref-doc-a.txt] ; set b [mkbuf pref-doc-b.txt]
refresh_tabs ; update idletasks
set ::tab_layout scroll ; tab_layout_apply
.prefs.body.view.mtab invoke          ;# -> multi
ok "tabs: window set multi"      $::tab_layout                         multi
ok "tabs: strip re-flowed packed" [winfo manager [gget 0 tabs].b$a]    pack
.prefs.body.view.mtab invoke          ;# -> back to scroll
ok "tabs: window set scroll"     $::tab_layout                         scroll

# --- the category switch selects, and prefs_show_cat is safe with a selection ------
.prefs.cats selection clear 0 end
.prefs.cats selection set 1
prefs_show_cat .prefs
ok "category: selects editor"    [.prefs.cats get [.prefs.cats curselection]] Editor

# --- the theme dropdown is enumerated from the core and shows the current label ----
ok "view: theme is a dropdown"   [winfo class .prefs.body.view.theme]  Menubutton
ok "view: theme menu enumerated" [expr {[.prefs.body.view.theme.m index end] >= 0}] 1
# The button text is the pretty label plus a ▾ chevron (so a bare menubutton reads as a
# dropdown); it tracks ::theme_choice.
ok "view: chevron on the label"  [string match "*▾" $::theme_choice_label] 1
ok "view: label tracks choice"   [string match "[theme_label $::theme_choice]*" $::theme_choice_label] 1
# Picking from the dropdown drives ::theme_choice (same global the View menu binds) and
# the tracked label follows — the two-door sync, dropdown edition.
set _lbl [.prefs.body.view.theme.m entrycget 0 -label]
.prefs.body.view.theme.m invoke 0
ok "view: pick sets label"       [string match "$_lbl*" $::theme_choice_label] 1
ok "view: Font has a heading"    [winfo exists .prefs.body.view.fontl]  1

# --- editing-mode radios are enumerated (not hard-coded) ---------------------------
ok "editor: mode radios built"   [winfo exists .prefs.body.editor.em1] 1
ok "editor: windows is a mode"   [expr {"windows" in [rio::modes::names]}] 1

# --- opening twice reuses the window rather than erroring --------------------------
ok "reopen: no second toplevel"  [catch {preferences_window}]          0
ok "reopen: window still there"  [winfo exists .prefs]                 1

# --- the Settings menu carries the entry point, keyboard default unbound -----------
ok "menu: Preferences in Settings" [.m.settings type "Preferences…"]   command
ok "keymap: default unbound"     [lindex [dict get $::keymap_default preferences] 0] ""

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

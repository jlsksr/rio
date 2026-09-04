#!/usr/bin/env wish
#
# Headless editor-font test for rio-gui (AGENTS.md D56): the document view's font is a
# user preference layered over the theme's named font. Checks that with no override the
# font follows the theme, that zoom steps/clamps/resets an absolute size override, that
# a family override applies live, that both persist through prefs.json, and that a theme
# switch keeps the override rather than discarding it. Needs a DISPLAY (Tk); no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/font.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this
# file's own non-ASCII expectations arrive mojibake and fail against the correctly-
# decoded values the GUI produces. The same guard the rio-gui and server entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
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
proc ef_size {}   { return [font configure RioEditorFont -size] }
proc ef_family {} { return [font configure RioEditorFont -family] }

# --- no override: the editor font follows the theme (default: monospace 12) --------
ok "theme base recorded: size"   $::editor_theme_size   12
ok "theme base recorded: family" $::editor_theme_family monospace
ok "no override -> theme size"   [ef_size]              12
ok "size_now reads theme"        [editor_font_size_now] 12
ok "override size starts 0"      $::editor_font_size    0

# --- zoom steps an ABSOLUTE size override -----------------------------------------
editor_zoom 1
ok "zoom in: override set"        $::editor_font_size 13
ok "zoom in: font moved"          [ef_size]           13
editor_zoom 1
ok "zoom in again"                [ef_size]           14
editor_zoom -1
ok "zoom out"                     [ef_size]           13

# --- zoom clamps at the ends ------------------------------------------------------
set ::editor_font_size 72 ; apply_editor_font
editor_zoom 1
ok "zoom clamps at 72"            [ef_size]           72
set ::editor_font_size 5 ; apply_editor_font
editor_zoom -1
ok "zoom clamps at 5"             [ef_size]           5

# --- reset drops the size override, back to the theme -----------------------------
editor_zoom_reset
ok "reset: override cleared"      $::editor_font_size 0
ok "reset: font back to theme"    [ef_size]           12

# --- a family override applies live ------------------------------------------------
set ::editor_font_family "Courier New" ; apply_editor_font
ok "family override applied"      [ef_family]         "Courier New"

# --- both overrides persist through prefs.json ------------------------------------
set ::editor_font_size 18 ; apply_editor_font
prefs_save
set ::editor_font_family "" ; set ::editor_font_size 0   ;# wipe in-memory
prefs_load
ok "persist: family reloaded"     $::editor_font_family "Courier New"
ok "persist: size reloaded"       $::editor_font_size   18

# --- an out-of-range persisted size is ignored, theme size kept -------------------
set ::editor_font_size 999
apply_editor_font                                   ;# clamp is a load-time guard, not here
set ::editor_font_size 0                            ;# reset before re-loading a bad value
# hand-write a prefs file with a bogus size and confirm prefs_load rejects it
set pf [prefs_path]
set f [open $pf {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
puts -nonewline $f {{"theme":"default","font_family":"Courier New","font_size":999}} ; close $f
set ::editor_font_size 7
prefs_load
ok "persist: bad size rejected"   $::editor_font_size 7   ;# left as it was, not 999

# --- a theme switch KEEPS the override (does not silently discard it) --------------
set ::editor_font_family "Courier New" ; set ::editor_font_size 20 ; apply_editor_font
do_theme default                                    ;# re-fetch + apply the theme
ok "theme switch keeps size"      [ef_size]           20
ok "theme switch keeps family"    [ef_family]         "Courier New"
editor_zoom_reset ; set ::editor_font_family "" ; apply_editor_font

# --- the widget carries the zoom bindings, and the menu carries the commands ------
set w [gget $::focus path]
ok "bind: Ctrl+wheel present"     [expr {[string match *editor_zoom* [bind $w <Control-MouseWheel>]]}] 1
ok "bind: Ctrl+plus present"      [expr {[string match *editor_zoom* [bind $w <Control-plus>]]}]       1
ok "bind: Ctrl+0 resets"          [expr {[string match *editor_zoom_reset* [bind $w <Control-Key-0>]]}] 1
ok "menu: Font item present"      [expr {[.m.view.zoom index "Font…"] ne ""}] 1
ok "menu: Reset Zoom present"     [expr {[.m.view.zoom index "Reset Zoom"] ne ""}] 1

# a freshly split group inherits the zoom bindings too
set g [add_group]
set nw [gget $g path]
ok "split: new group has zoom"    [expr {[string match *editor_zoom* [bind $nw <Control-MouseWheel>]]}] 1
unsplit_editor

# --- the Font dialog pre-selects the current family, even with no override ---------
# The theme records a logical alias (`monospace`) that `font families` never lists, so
# the dialog used to open with nothing marked. It now resolves the concrete family via
# `font actual` and highlights it, so the user sees what is in use before choosing.
set ::editor_font_family "" ; apply_editor_font   ;# back to the theme font (no override)
editor_font_dialog
update idletasks
set want [font actual RioEditorFont -family]
set sel  [.efont.body.fam.list curselection]
ok "font dialog: a family is marked"  [expr {$sel ne ""}] 1
ok "font dialog: marks current family" [.efont.body.fam.list get $sel] $want
destroy .efont

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

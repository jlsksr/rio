#!/usr/bin/env wish
#
# Headless hover-tooltip test for rio-gui (AGENTS.md D63). rio's little header controls are
# bare glyphs (⟳ refresh, ◉/◌ hidden toggle) with no text label; `tooltip $w $text` names
# them on hover via one shared borderless toplevel (.tt), shown after a delay and hidden on
# leave. Checks: attaching stashes the text and binds <Enter>/<Leave>; re-calling updates
# the text with no extra toplevel; showing builds .tt with the widget's text and hiding
# withdraws it; the files/git Refresh glyphs carry "Refresh"; and the hidden toggle
# re-labels itself per state through nav_hidden_glyph. Needs a DISPLAY (creates .tt).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/tooltip.tcl

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

# --- attaching stashes the text and binds the hover events ---------------------------
tooltip .pfiles.hdr.refresh "Refresh"
ok "attach: text stashed"        $::tt_text(.pfiles.hdr.refresh) Refresh
ok "attach: Enter bound"         [expr {[bind .pfiles.hdr.refresh <Enter>] ne ""}] 1
ok "attach: Leave bound"         [expr {[bind .pfiles.hdr.refresh <Leave>] ne ""}] 1

# --- the two pane-header Refresh glyphs, and re-attach just updates the text ----------
ok "files refresh: Refresh text" $::tt_text(.pfiles.hdr.refresh) Refresh
ok "git refresh: Refresh text"   $::tt_text(.pgit.hdr.refresh)   Refresh
tooltip .pfiles.hdr.refresh "Reload"
ok "re-attach: text updated"     $::tt_text(.pfiles.hdr.refresh) Reload
tooltip .pfiles.hdr.refresh "Refresh"   ;# restore

# --- the hidden toggle re-labels itself per state (via nav_hidden_glyph) -------------
set ::show_hidden 0 ; nav_hidden_glyph
ok "hidden off: says Show"       $::tt_text(.pfiles.hdr.hidden) "Show hidden files"
set ::show_hidden 1 ; nav_hidden_glyph
ok "hidden on: says Hide"        $::tt_text(.pfiles.hdr.hidden) "Hide hidden files"
set ::show_hidden 0 ; nav_hidden_glyph

# --- showing builds the shared popup with the widget's text; hiding withdraws it ------
tooltip_show .pfiles.hdr.refresh
ok "show: popup exists"          [winfo exists .tt] 1
ok "show: popup carries text"    [.tt.l cget -text] Refresh
ok "show: only one toplevel"     [winfo exists .tt2] 0
tooltip_show .pgit.hdr.refresh   ;# reuses the same .tt, new text
ok "show: reuses one popup"      [.tt.l cget -text] Refresh
tooltip_hide
ok "hide: popup withdrawn"       [wm state .tt] withdrawn

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

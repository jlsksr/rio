#!/usr/bin/env wish
#
# Headless keymap test for rio-gui (AGENTS.md D23): the shortcut table is data, one
# stop for all hotkey config. Checks that the defaults resolve, that a chord renders
# to the right menu-accelerator label, that a user keys.json overrides / unbinds a
# command, that garbage is skipped (not fatal) and recorded, and that the resolved map
# actually drives the per-widget bindings. Needs a DISPLAY (Tk); shows no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/keymap.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31); also holds our keys.json
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
# Write a keys.json into the sandbox config dir (where keys_path points).
proc write_keys {json} {
	set p [keys_path]
	file mkdir [file dirname $p]
	set f [open $p {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
	puts -nonewline $f $json ; close $f
}

# --- defaults resolve (no keys.json yet in the sandbox) ----------------------
ok "default: new"            [key_chord new]            Control-n
ok "default: close-tab"      [key_chord close-tab]      Control-w
ok "default: split-editor"   [key_chord split-editor]   Control-backslash
ok "default: unknown -> {}"  [key_chord nope]           ""

# --- chord -> accelerator label ----------------------------------------------
ok "label: plain letter"     [chord_label Control-n]          Ctrl+N
ok "label: implicit shift"   [chord_label Control-S]          Ctrl+Shift+S
ok "label: explicit shift"   [chord_label Control-Shift-Tab]  Ctrl+Shift+Tab
ok "label: backslash glyph"  [chord_label Control-backslash]  "Ctrl+\\"
ok "label: bracket glyph"    [chord_label Control-bracketright] "Ctrl+]"
ok "label: named key as-is"  [chord_label Control-Tab]        Ctrl+Tab
ok "label: unbound -> {}"    [chord_label ""]                 ""
ok "accel: via command"      [key_accel move-tab-other]       "Ctrl+]"

# --- the resolved map drives the real per-widget bindings --------------------
set w [gget $::focus path]
ok "bind: default present"   [expr {[string match *do_new* [bind $w <Control-n>]]}] 1

# --- a user keys.json overrides, unbinds, and rejects garbage ----------------
write_keys {{
	"close-tab": "Control-k",
	"quit": "",
	"bogus-command": "Control-b",
	"save": "Nonsense-chord"
}}
keymap_resolve

ok "override: remapped chord"   [key_chord close-tab]  Control-k
ok "override: menu label moved" [key_accel close-tab]  Ctrl+K
ok "unbind: empty chord kept"   [key_chord quit]       ""
ok "reject: unknown untouched"  [dict exists $::keymap bogus-command] 0
ok "reject: bad chord -> default" [key_chord save]     Control-s
ok "bad: two entries noted"     [llength $::keymap_bad] 2

# rebinding a fresh widget honours the override and drops the unbound command
set g [add_group]
set nw [gget $g path]
ok "rebind: override bound"      [expr {[string match *do_close* [bind $nw <Control-k>]]}] 1
ok "rebind: old chord cleared"   [bind $nw <Control-w>] ""
ok "rebind: unbound has no key"  [bind $nw <Control-q>] ""
unsplit_editor

# --- a corrupt keys.json is ignored, editor still resolves to defaults -------
write_keys {not json at all}
keymap_resolve
ok "corrupt: falls back to default" [key_chord new]        Control-n
ok "corrupt: noted once"            [llength $::keymap_bad] 1

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

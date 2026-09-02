#!/usr/bin/env wish
#
# Headless keymap test for rio-gui (AGENTS.md D23): the shortcut table is data, one
# stop for all hotkey config. Checks that the defaults resolve, that a chord renders
# to the right menu-accelerator label, that a user keys.json overrides / unbinds a
# command, that garbage is skipped (not fatal) and recorded, and that the resolved map
# actually drives the per-widget bindings. Needs a DISPLAY (Tk); shows no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/keymap.tcl

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

# --- friendly command labels (for the shortcuts editor) ----------------------
ok "label: friendly name"    [key_label close-tab]  "Close tab"
ok "label: unknown -> id"    [key_label nope]       nope

# --- event_to_chord: a key event (%K keysym, %s state) -> chord --------------
# state bits: Shift 0x1, Control 0x4, Alt/Mod1 0x8.
ok "ev: ctrl+letter"          [event_to_chord k 4]           Control-k
ok "ev: ctrl+shift+letter"    [event_to_chord K 5]           Control-Shift-k
ok "ev: ctrl+alt"             [event_to_chord n 12]          Control-Alt-n
ok "ev: named key kept"       [event_to_chord backslash 4]   Control-backslash
ok "ev: bare function key ok" [event_to_chord F5 0]          F5
ok "ev: bare letter refused"  [event_to_chord a 0]           ""
ok "ev: bare modifier refused" [event_to_chord Control_L 4]  ""

# --- keys_conflict: another command already using a chord --------------------
set wk {new Control-n save Control-s close-tab Control-w}
ok "conflict: detects other" [keys_conflict $wk new Control-s] save
ok "conflict: free chord"    [keys_conflict $wk new Control-x] ""
ok "conflict: same command"  [keys_conflict $wk new Control-n] ""
ok "conflict: empty never"   [keys_conflict $wk new ""]        ""

# --- keymap_overrides: minimal diff against the defaults ---------------------
set wk2 {}
dict for {cmd spec} $::keymap_default { dict set wk2 $cmd [lindex $spec 0] }
ok "overrides: none at default" [keymap_overrides $wk2] ""
dict set wk2 close-tab Control-k
dict set wk2 quit ""
set ov [keymap_overrides $wk2]
ok "overrides: remap present"   [dict get $ov close-tab] Control-k
ok "overrides: unbind present"  [dict get $ov quit]      ""
ok "overrides: only the diffs"  [dict size $ov]          2

# --- keys_default: restore one command to its shipped default (per-row button) ---
set ::keys_work [dict create close-tab Control-k quit ""]
keys_default close-tab
ok "one-default: restores chord" [dict get $::keys_work close-tab] Control-w
ok "one-default: leaves others"  [dict get $::keys_work quit]      ""

# --- keys_save round-trips through keys.json and deletes when empty ----------
keys_save {close-tab Control-k}
ok "save: wrote a file"    [file exists [keys_path]] 1
keymap_resolve
ok "save: resolves back"   [key_chord close-tab]     Control-k
keys_save {}
ok "save: empty deletes"   [file exists [keys_path]] 0

# --- live remap: keymap_apply_live rebinds widgets + menu, no restart --------
set w [gget $::focus path]
write_keys {{"close-tab": "Control-k"}}
keymap_apply_live
ok "live: new chord bound"    [string match *do_close* [bind $w <Control-k>]] 1
ok "live: old chord cleared"  [bind $w <Control-w>] ""
ok "live: menu label moved"   [.m.file entrycget "Close Tab" -accelerator] Ctrl+K
write_keys {{}}
keymap_apply_live
ok "live: default re-bound"   [string match *do_close* [bind $w <Control-w>]] 1
ok "live: override cleared"   [bind $w <Control-k>] ""
ok "live: menu label restored" [.m.file entrycget "Close Tab" -accelerator] Ctrl+W

# --- the shortcuts editor, driven end to end ---------------------------------
# Open the real modal, then (once it's up, via the event loop tkwait runs) record a
# chord and Save — calling the capture handlers directly, exactly as a keypress would.
after 80 {
	ok "dialog: window built"     [winfo exists .keys.body.kclose-tab] 1
	keys_capture close-tab
	keys_on_key k 4                       ;# as if the user pressed Ctrl+K
	set ::probe [.keys.body.kclose-tab cget -text]
	keys_dialog_save                      ;# writes keys.json, applies live, closes
}
keybindings_dialog                        ;# blocks until the after-script closes it
ok "dialog: button showed chord"  $::probe Ctrl+K
ok "dialog: saved + resolved"     [key_chord close-tab]                          Control-k
ok "dialog: bound live on widget" [string match *do_close* [bind $w <Control-k>]] 1

after 80 { keys_reset_all ; keys_dialog_save }
keybindings_dialog
ok "dialog: reset removes file"   [file exists [keys_path]]  0
ok "dialog: reset restores default" [key_chord close-tab]    Control-w

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

#!/usr/bin/env wish
#
# Headless keymap test for rio-gui (D23): the shortcut table is data, one
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
# This platform's primary modifier (D136): the defaults below are Control-… on X11 and
# Windows and Command-… on a Mac, so the checks of what is IN FORCE use these. The Mac's
# own table is checked explicitly further down, on every host.
set P  $::primary_mod
set PL $::primary_label
# Write a keys.json into the sandbox config dir (where keys_path points).
proc write_keys {json} {
	set p [keys_path]
	file mkdir [file dirname $p]
	set f [open $p {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
	puts -nonewline $f $json ; close $f
}

# --- defaults resolve (no keys.json yet in the sandbox) ----------------------
ok "default: new"            [key_chord new]            $P-n
ok "default: close-tab"      [key_chord close-tab]      $P-w
ok "default: split-editor"   [key_chord split-editor]   $P-backslash
ok "default: unknown -> {}"  [key_chord nope]           ""

# --- chord -> accelerator label ----------------------------------------------
ok "label: plain letter"     [chord_label Control-n]          Ctrl+N
ok "label: implicit shift"   [chord_label Control-S]          Ctrl+Shift+S
ok "label: explicit shift"   [chord_label Control-Shift-Tab]  Ctrl+Shift+Tab
ok "label: backslash glyph"  [chord_label Control-backslash]  "Ctrl+\\"
ok "label: bracket glyph"    [chord_label Control-bracketright] "Ctrl+]"
ok "label: named key as-is"  [chord_label Control-Tab]        Ctrl+Tab
ok "label: unbound -> {}"    [chord_label ""]                 ""
ok "accel: via command"      [key_accel move-tab-other]       "$PL+]"

# --- the resolved map drives the real per-widget bindings --------------------
set w [gget $::focus path]
ok "bind: default present"   [expr {[string match *do_new* [bind $w <$P-n>]]}] 1

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
ok "reject: bad chord -> default" [key_chord save]     $P-s
ok "bad: two entries noted"     [llength $::keymap_bad] 2

# rebinding a fresh widget honours the override and drops the unbound command
set g [add_group]
set nw [gget $g path]
ok "rebind: override bound"      [expr {[string match *do_close* [bind $nw <Control-k>]]}] 1
ok "rebind: old chord cleared"   [bind $nw <$P-w>] ""
ok "rebind: unbound has no key"  [bind $nw <$P-q>] ""
unsplit_editor

# --- a corrupt keys.json is ignored, editor still resolves to defaults -------
write_keys {not json at all}
keymap_resolve
ok "corrupt: falls back to default" [key_chord new]        $P-n
ok "corrupt: noted once"            [llength $::keymap_bad] 1

# --- friendly command labels (for the shortcuts editor) ----------------------
ok "label: friendly name"    [key_label close-tab]  "Close tab"
ok "label: unknown -> id"    [key_label nope]       nope

# --- event_to_chord: a key event (%K keysym, %s state) -> chord --------------
# state bits on X11 and Windows: Shift 0x1, Control 0x4, Alt/Mod1 0x8. (A Mac's are below.)
ok "ev: ctrl+letter"          [event_to_chord k 4 x11]         Control-k
ok "ev: ctrl+shift+letter"    [event_to_chord K 5 x11]         Control-Shift-k
ok "ev: ctrl+alt"             [event_to_chord n 12 x11]         Control-Alt-n
ok "ev: named key kept"       [event_to_chord backslash 4 x11]   Control-backslash
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
dict set wk2 open ""    ;# not quit: on a Mac that is unbound by default (D136)
set ov [keymap_overrides $wk2]
ok "overrides: remap present"   [dict get $ov close-tab] Control-k
ok "overrides: unbind present"  [dict get $ov open]      ""
ok "overrides: only the diffs"  [dict size $ov]          2

# --- keys_default: restore one command to its shipped default (per-row button) ---
set ::keys_work [dict create close-tab Control-k quit ""]
keys_default close-tab
ok "one-default: restores chord" [dict get $::keys_work close-tab] $P-w
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
ok "live: old chord cleared"  [bind $w <$P-w>] ""
ok "live: menu label moved"   [.m.file entrycget "Close Tab" -accelerator] Ctrl+K
write_keys {{}}
keymap_apply_live
ok "live: default re-bound"   [string match *do_close* [bind $w <$P-w>]] 1
ok "live: override cleared"   [bind $w <Control-k>] ""
ok "live: menu label restored" [.m.file entrycget "Close Tab" -accelerator] $PL+W

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
ok "dialog: reset restores default" [key_chord close-tab]    $P-w

# --- the Mac (D136), checked on any host --------------------------------------
# The table as a Mac reads it: Command wherever the table says Control, except the
# chords ::keymap_aqua names.
set mac [keymap_for_platform $::keymap_base aqua]
proc mc {cmd} { lindex [dict get $::mac $cmd] 0 }
ok "mac: Control becomes Command"          [mc save]      Command-s
ok "mac: an implicit Shift survives"       [mc save-as]   Command-S
ok "mac: a keysym key too"                 [mc split-editor] Command-backslash
ok "mac: a key with no Control is left"    [mc find-next] F3
ok "mac: quit is the application menu's"   [mc quit]      ""
ok "mac: replace is Opt+Cmd+F, not Cmd+H"  [mc replace]   Option-Command-function
ok "mac: ...and its label reads so"        [chord_label [mc replace] aqua] Opt+Cmd+F
ok "mac: tab cycling keeps Control"        [mc next-tab]  Control-Tab
ok "mac: ...both ways"                     [mc prev-tab]  Control-Shift-Tab
ok "mac: action and label untouched"       [lrange [dict get $mac save] 1 2] \
	[lrange [dict get $::keymap_base save] 1 2]
ok "mac: every command still there"        [dict keys $mac] [dict keys $::keymap_base]
# Derived, not listed: nothing is left on Control but what the exception table says.
set stray {}
dict for {cmd spec} $mac {
	if {[string match Control-* [lindex $spec 0]] && ![dict exists $::keymap_aqua $cmd]} { lappend stray $cmd }
}
ok "mac: no stray Control chord" $stray {}
# No Mac default may be a chord the application menu (Quit ⌘Q, Hide ⌘H, Hide Others ⌥⌘H,
# Preferences ⌘,) or the system (app switcher ⌘Tab, Spotlight ⌘Space) already owns: it
# would fire twice, or not at all (tkMacOSXMenus.c builds that menu).
set taken {}
dict for {cmd spec} $mac {
	set c [lindex $spec 0]
	if {$c in {Command-q Command-h Option-Command-h Command-comma Command-Tab Command-space}} {
		lappend taken "$cmd $c"
	}
}
ok "mac: no chord the application menu or the system owns" $taken {}
# Every Mac chord is a pattern Tk accepts. Tk knows Command and Option on every platform
# (they are Mod1 and Mod2, tkBind.c), so a typo here fails on any host, not only on a Mac.
frame .probe
set unbindable {}
dict for {cmd spec} $mac {
	set c [lindex $spec 0]
	if {$c ne "" && [catch {bind .probe <$c> {}}]} { lappend unbindable "$cmd $c" }
}
destroy .probe
ok "mac: every chord is one Tk will bind" $unbindable {}
ok "off a Mac: the table as written"   [keymap_for_platform $::keymap_base x11]   $::keymap_base
ok "off a Mac: Windows too"            [keymap_for_platform $::keymap_base win32] $::keymap_base
ok "in force: this platform's table"   $::keymap_default \
	[keymap_for_platform $::keymap_base [tk windowingsystem]]
# The labels a Mac shows, in its own order (⌃⌥⇧⌘)...
ok "mac label: Cmd+S"                   [chord_label Command-s aqua]         Cmd+S
ok "mac label: Shift before Cmd"        [chord_label Command-S aqua]         Shift+Cmd+S
ok "mac label: Opt+Cmd+F"               [chord_label Option-Command-f aqua]  Opt+Cmd+F
ok "mac label: Mod1 is Command there"   [chord_label Mod1-s aqua]            Cmd+S
ok "x11 label: Mod1 is Alt"             [chord_label Mod1-s x11]             Alt+S
ok "mac label: Control stays Ctrl"      [chord_label Control-Tab aqua]       Ctrl+Tab
# ...and only in words Tk's Mac menus parse into a native key equivalent (the modifier
# names ParseAccelerator knows, tkMacOSXMenu.c). A word it did not know would be drawn
# as literal text and the menu would lose its ⌘ glyph.
set unparsed {}
dict for {cmd spec} $mac {
	set l [chord_label [lindex $spec 0] aqua]
	foreach m [lrange [split $l +] 0 end-1] {
		if {$m ni {Control Ctrl Option Opt Alt Shift Command Cmd Meta}} { lappend unparsed "$cmd $l" }
	}
}
ok "mac label: every modifier word is one Tk's Mac menus parse" $unparsed {}
# The recorder on a Mac: 0x8 (Mod1) is Command and 0x10 (Mod2) is Option. Tk's Alt matches
# no key at all there, so a Cmd chord recorded as Alt-… would never fire.
ok "mac ev: cmd+letter"       [event_to_chord s 8 aqua]        Command-s
ok "mac ev: shift+cmd"        [event_to_chord S 9 aqua]        Shift-Command-s
ok "mac ev: opt+cmd"          [event_to_chord function 24 aqua] Option-Command-function
ok "mac ev: ⌥⌘F records the shipped default" [event_to_chord function 24 aqua] [mc replace]
ok "mac ev: ctrl stays"       [event_to_chord k 4 aqua]        Control-k
ok "mac ev: never Alt"        [string match *Alt* [event_to_chord n 12 aqua]] 0
ok "mac ev: a bare letter is still refused" [event_to_chord a 0 aqua] ""
ok "mac ev: what it records is a valid chord" [keymap_valid [event_to_chord f 24 aqua]] 1
# On a Mac itself: the Replace chord through Tk's REAL key lookup. `event generate -keysym`
# turns the keysym into a keycode, and Tk then derives the keysym back from the keycode and
# the state (TkpGetKeySym), through the Option layer — exactly what a real ⌥⌘F goes through.
# The checks above hand chords around as strings and so could never see that ⌥F is ƒ; this
# one does. Only meaningful on Aqua: elsewhere Option has no layer to look through.
if {[tk windowingsystem] eq "aqua"} {
	# A toplevel of its own, off-screen and unmanaged (D127): the suite's `.` is withdrawn
	# and cannot take focus, and key events only ever go to the focus.
	toplevel .kp ; wm overrideredirect .kp 1 ; wm geometry .kp +-4000+-4000
	entry .kp.e ; pack .kp.e ; update
	set ::khit {}
	bind .kp.e <[key_chord replace]> {lappend ::khit shipped}
	bind .kp.e <Option-Command-f>    {lappend ::khit letter}
	focus -force .kp.e ; update
	event generate .kp.e <KeyPress> -keysym f -state 0x18 -when now  ;# Mod1|Mod2: ⌘ ⌥
	ok "aqua: a real ⌥⌘F reaches the shipped Replace chord" [lindex $::khit 0] shipped
	destroy .kp
}

# In force on THIS platform: the menus carry this platform's labels.
ok "menu: Save shows this platform's modifier" \
	[.m.file entrycget "Save" -accelerator] "$PL+S"

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

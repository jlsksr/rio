#!/usr/bin/env wish
#
# Headless test for the frontend half of autosave (AGENTS.md D132). The engine, the policy
# and the copies are the core's — rio-core/tests/autosave.test covers those. What is here is
# what a frontend owns: the one door onto the core's setting, and the question a recovery
# copy raises (D125 — the core states the fact, the frontend owns the question).
#
# Checks the Preferences control (its variable, its applier, that it reaches the core and
# mirrors back what the core accepted, and that a refusal leaves it honest), the prompt on
# an interactive open in both answers, that recovering marks the buffer modified and leaves
# the file on disk alone, which way the default button falls, and that a boot restore asks
# ONCE for the whole set instead of once per file.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/autosave.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows); this file's own
# non-ASCII expectations (the “” quotes in the prompt) would then arrive mojibake. Re-source
# under UTF-8 — the guard every runnable script carries (D54). No-op where it is already so.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31): the copies
                                                             ;# land under the sandbox too
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
proc spit {p s} {
	file mkdir [file dirname $p]
	set f [open $p w] ; fconfigure $f -translation binary ; puts -nonewline $f $s ; close $f
}
proc slurp {p} { set f [open $p rb] ; set s [read $f] ; close $f ; return $s }
proc shown {} { return [::rio_real_t get 1.0 end-1c] }

# The core runs IN THIS INTERPRETER (the suite sources server.tcl and connects to it over a
# real socket), so the copies land under the sandbox's own XDG_DATA_HOME and rio::autosave
# is directly callable for the fixtures.
proc ascopy {p} { return [rio::autosave::path_for $p] }

# Plant a recovery copy for a file nothing has open — which is what a crash leaves behind.
# Better than closing a buffer to simulate one: buffer.close DROPS the copy, correctly, so a
# closed tab could never stand in for a core that died. The file is aged so the copy is
# unambiguously the newer of the two (mtime is whole seconds on some filesystems).
proc plant_copy {p text {older 0}} {
	set ap [ascopy $p]
	spit $ap $text
	if {$older} {
		file mtime $ap [expr {[file mtime $p] - 5}]
	} else {
		file mtime $p [expr {[file mtime $ap] - 5}]
	}
	return $ap
}

set ::dir [file join $::sandbox_dir proj]
file mkdir $::dir
proc fixture {name {text "original\n"}} {
	set p [file join $::dir $name]
	spit $p $text
	return $p
}

# The prompt, recorded rather than shown — the reload.tcl idiom. Both arguments are kept:
# the question's wording is asserted, and `newer` is what picks the default button.
set ::asked {}
set ::answer yes
rename recover_ask _real_recover_ask
proc recover_ask {q newer} { lappend ::asked [list $q $newer] ; return $::answer }

# A refusal is reported through report_error, which is a modal; record it instead.
set ::reported {}
rename report_error _real_report_error
proc report_error {msg {code ""}} { lappend ::reported [list $code $msg] }

# --- 1. the one door: Preferences ▸ Editor ----------------------------------------------

preferences_window
ok "prefs: the control exists"        [winfo exists .prefs.body.editor.as]          1
ok "prefs: it drives ::autosave_on"   [.prefs.body.editor.as cget -variable]        ::autosave_on
ok "prefs: and calls the applier"     [.prefs.body.editor.as cget -command]         autosave_set
ok "prefs: its label says what it is" [.prefs.body.editor.as cget -text] \
	"Keep recovery files for unsaved changes"
ok "prefs: a muted hint sits under it" \
	[expr {[winfo exists .prefs.body.editor.ashint] &&
		[.prefs.body.editor.ashint cget -foreground] eq [dict get $::theme_colors gutter.fg]}] 1
# One door on purpose (D85): a set-once policy earns no menu twin.
set ::menu_twin 0
foreach m {.m.view .m.settings} {
	for {set i 0} {$i <= [$m index end]} {incr i} {
		if {[catch {$m entrycget $i -variable} v]} continue
		if {$v eq "::autosave_on"} { set ::menu_twin 1 }
	}
}
ok "prefs: no menu twin"              $::menu_twin                                  0

# --- 2. it reaches the core, and mirrors back what the core accepted --------------------

ok "default: on"                      $::autosave_on                                1
set ::autosave_on 0 ; autosave_set   ;# as the checkbutton leaves it, then its -command
ok "unticked: the core agrees"        [dict get [rio_call autosave.settings {}] result enabled] 0
ok "unticked: the mirror agrees"      $::autosave_on                                0
ok "unticked: autosave.conf written"  [file exists [rio::autosave::settings_path]]   1
set ::autosave_on 1 ; autosave_set
ok "re-ticked: the core agrees"       [dict get [rio_call autosave.settings {}] result enabled] 1

# A change made core-side — by another frontend, or by hand in autosave.conf — is picked up
# at the next attach and never pushed over.
rio_call autosave.settings.set [dict create enabled 0]
set ::autosave_on 1                   ;# a stale mirror
adopt_autosave_settings
ok "attach mirrors the core"          $::autosave_on                                0
rio_call autosave.settings.set [dict create enabled 1]
adopt_autosave_settings
ok "attach mirrors it back"           $::autosave_on                                1

# A refusal must leave the control showing what the core actually holds, not what was
# clicked. Point the core's conf at a path it cannot write (its parent is a plain file).
set ::blocker [file join $::sandbox_dir notadir]
spit $::blocker "x\n"
set ::realconf [rio::autosave::settings_path]
set rio::autosave::settings_override [file join $::blocker sub autosave.conf]
set ::reported {}
set ::autosave_on 0 ; autosave_set
ok "refused: reported once"           [llength $::reported]                         1
ok "refused: as an io_error"          [lindex $::reported 0 0]                      io_error
ok "refused: the control snaps back"  $::autosave_on                                1
set rio::autosave::settings_override ""

# --- 3. the question on an interactive open ---------------------------------------------

set ::asked {}
set p1 [fixture a1.txt]
do_open $p1
ok "no copy, no question"             $::asked                                      {}

set ::asked {} ; set ::answer yes
set p2 [fixture a2.txt]
plant_copy $p2 "recovered!\n"
do_open $p2
ok "a copy asks, once"                [llength $::asked]                            1
ok "the question names the file"      [regexp {a2\.txt} [lindex $::asked 0 0]]       1
ok "it promises the file is untouched" \
	[regexp {file itself is not touched} [lindex $::asked 0 0]]                      1
ok "taken back: the buffer has it"    [shown]                                       "recovered!\n"
ok "taken back: the core has it too"  [dict get [rio_call buffer.text [dict create buffer $::cur]] result text] \
	"recovered!\n"
ok "taken back: and is modified"      [bufget $::cur modified]                      1
ok "taken back: the file is untouched" [slurp $p2]                                  "original\n"
# Undoable, like any other edit (the core makes it one step; this proves the frontend's
# path back is the ordinary one).
do_undo
ok "taken back: undo returns the file" [shown]                                      "original\n"

set ::asked {} ; set ::answer no
set p3 [fixture a3.txt]
plant_copy $p3 "not wanted\n"
do_open $p3
ok "declined: still asked"            [llength $::asked]                            1
ok "declined: the buffer is the file" [shown]                                       "original\n"
ok "declined: not modified"           [bufget $::cur modified]                      0
ok "declined: the copy is left alone" [file exists [ascopy $p3]]                    1

# --- 4. which way the default button falls ----------------------------------------------

set ::asked {} ; set ::answer no
set p4 [fixture a4.txt]
plant_copy $p4 "older\n" 1            ;# the FILE is the newer of the two
do_open $p4
ok "an older copy is still offered"   [llength $::asked]                            1
ok "…and says so"                     [regexp {OLDER} [lindex $::asked 0 0]]         1
ok "…and is flagged not newer"        [lindex $::asked 0 1]                         0

# The real prompt's own rule: default to the choice that loses nothing (D94), which for an
# older copy is not nodding through older text.
rename tk_messageBox _guard_tk_messageBox
proc tk_messageBox {args} { return [dict get $args -default] }
ok "newer defaults to Yes"            [_real_recover_ask q 1]                       yes
ok "older defaults to No"             [_real_recover_ask q 0]                       no
rename tk_messageBox {}
rename _guard_tk_messageBox tk_messageBox

# --- 5. a boot restore asks once for the whole set --------------------------------------

set ::asked {} ; set ::answer yes
set ::recover_pending {}
set ::rio_started 0                   ;# as during a session restore
set p5 [fixture a5.txt] ; plant_copy $p5 "five!\n"
set p6 [fixture a6.txt] ; plant_copy $p6 "six!\n"
do_open $p5
do_open $p6
ok "boot: asks nothing yet"           $::asked                                      {}
ok "boot: both queued"                [llength $::recover_pending]                  2
set ::rio_started 1
recover_flush                         ;# the very call the boot sequence makes
ok "boot: ONE dialog for the set"     [llength $::asked]                            1
ok "boot: it lists both files"        [expr {[regexp {a5\.txt} [lindex $::asked 0 0]] &&
	[regexp {a6\.txt} [lindex $::asked 0 0]]}]                                       1
ok "boot: it says how many"           [regexp {^2 of the files} [lindex $::asked 0 0]] 1
ok "boot: the queue is emptied"       $::recover_pending                            {}
set ::b5 "" ; set ::b6 ""
foreach id [dict keys $::buffers] {
	if {[bufget $id path] eq $p5} { set ::b5 $id }
	if {[bufget $id path] eq $p6} { set ::b6 $id }
}
ok "boot: the first was recovered"    [dict get [rio_call buffer.text [dict create buffer $::b5]] result text] "five!\n"
ok "boot: the second too"             [dict get [rio_call buffer.text [dict create buffer $::b6]] result text] "six!\n"
ok "boot: both modified"              [list [bufget $::b5 modified] [bufget $::b6 modified]] {1 1}
# Nothing queued is not a dialog.
set ::asked {}
recover_flush
ok "boot: an empty queue asks nothing" $::asked                                     {}

# --- 6. nothing reached a real dialog ---------------------------------------------------

ok "no stray dialog"                  $::headless_dialogs                           {}

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

#!/usr/bin/env wish
#
# Headless test for stale buffers (AGENTS.md D94): an open tab noticing the file changed
# under it. Drives the real loop — the core's buffers.stale/reload/stamp behind a socket,
# the GUI's check_stale_buffers deciding what to do with the answer — with only the two
# tk_messageBox prompts stubbed, since a modal has no one to answer it headless.
#
# What matters here is the DECIDING, so each case is set up as the user would have left
# it: clean vs modified, changed vs deleted, kept vs dropped.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/reload.tcl

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
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
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

# A file under the sandbox dir, and a rewrite of it. The mtime is pushed back a second so
# a same-second rewrite is unambiguously a different version whatever the filesystem's
# clock granularity is — the tests are about the decision, not about stat resolution.
proc mkfile {text} {
	file mkdir $::sandbox_dir
	set p [file join $::sandbox_dir f[incr ::fn].txt]
	set f [open $p wb] ; puts -nonewline $f $text ; close $f
	return $p
}
proc rewrite {p text} {
	set f [open $p wb] ; puts -nonewline $f $text ; close $f
	file mtime $p [expr {[file mtime $p] - 1}]
}
proc gtext {} { [gw $::focus] get 1.0 end-1c }
proc typ {s} { [gget $::focus path] insert 1.0 $s }   ;# through the proxy, so it records

# The two prompts, answered by the test. `::asked` records what was actually put to the
# user, so the wording and the fact of asking are both assertable.
set ::asked {}
set ::answer_changed no
set ::answer_deleted yes
rename stale_ask _real_stale_ask
rename stale_ask_deleted _real_stale_ask_deleted
proc stale_ask {q}         { lappend ::asked [list changed $q] ; return $::answer_changed }
proc stale_ask_deleted {q} { lappend ::asked [list deleted $q] ; return $::answer_deleted }
proc last_asked {} { return [lindex $::asked end] }

# --- a clean buffer reloads silently -----------------------------------------

set pA [mkfile "first\n"]
do_open $pA
set bA $::cur
ok "clean: opened text"          [gtext] "first\n"
rewrite $pA "second\n"
set ::asked {}
check_stale_buffers
ok "clean: reloaded from disk"   [gtext] "second\n"
ok "clean: nobody was asked"     [llength $::asked] 0
ok "clean: still unmodified"     [bufget $bA modified] 0
ok "clean: no longer stale"      [llength [dict get [rio_call buffers.stale {}] result stale]] 0

# The reload arrived as a buffer.changed and went through the ordinary edit path, so it
# is ONE undo step: Ctrl+Z gets the pre-reload text back.
do_undo
ok "clean: one undo step back"   [gtext] "first\n"
do_redo

# A file that has not changed is not touched at all — no reload, no prompt.
set ::asked {}
set _before [gtext]
check_stale_buffers
ok "quiet: unchanged is left alone" [list [gtext] [llength $::asked]] [list $_before 0]

# --- a modified buffer asks, and "no" keeps the edits ------------------------

set pB [mkfile "theirs\n"]
do_open $pB
set bB $::cur
typ "MINE "        ;# an unsaved edit, through the proxy
ok "conflict: buffer is modified" [bufget $bB modified] 1
rewrite $pB "theirs, rewritten\n"
set ::asked {}
set ::answer_changed no
check_stale_buffers
ok "conflict: the user was asked"  [lindex [last_asked] 0] changed
ok "conflict: named the file"      [string match "*[file tail $pB]*" [lindex [last_asked] 1]] 1
ok "conflict: warned about losing" [string match "*unsaved edits will be lost*" [lindex [last_asked] 1]] 1
ok "conflict: kept my text"        [string match "MINE *" [gtext]] 1
ok "conflict: still modified"      [bufget $bB modified] 1
# "No" stamps: the same change is not raised again on the next check.
set ::asked {}
check_stale_buffers
ok "conflict: not asked twice"     [llength $::asked] 0
# But a NEW change on disk is a version they have not seen, so it asks again.
rewrite $pB "theirs, a third time\n"
check_stale_buffers
ok "conflict: a new change asks again" [llength $::asked] 1

# --- "yes" takes the disk version, losing the edits --------------------------

set ::answer_changed yes
rewrite $pB "from disk, accepted\n"
check_stale_buffers
ok "accept: took the disk text"    [gtext] "from disk, accepted\n"
ok "accept: no longer modified"    [bufget $bB modified] 0

# --- deleted on disk: keep it in the editor ----------------------------------

set pC [mkfile "keep me\n"]
do_open $pC
set bC $::cur
file delete $pC
set ::asked {}
set ::answer_deleted yes
check_stale_buffers
ok "gone: the user was asked"      [lindex [last_asked] 0] deleted
ok "gone: said deleted on disk"    [string match "*deleted on disk*" [lindex [last_asked] 1]] 1
ok "gone: offered to recreate"     [string match "*recreate the file*" [lindex [last_asked] 1]] 1
ok "gone: tab still open"          [dict exists $::buffers $bC] 1
ok "gone: text still there"        [gtext] "keep me\n"
# Kept means it lives only here now, so Save must offer to write it back.
ok "gone: marked modified"         [bufget $bC modified] 1
ok "gone: acked"                   [bufget $bC gone_ack] 1
# And it is not asked about again on every focus return.
set ::asked {}
check_stale_buffers
ok "gone: not asked twice"         [llength $::asked] 0
# Saving recreates the file, and clears the ack.
do_save
ok "gone: save recreated the file" [file exists $pC] 1
ok "gone: ack cleared by save"     [bufget $bC gone_ack] 0
ok "gone: no longer modified"      [bufget $bC modified] 0

# --- deleted on disk: let it go ----------------------------------------------

set pD [mkfile "drop me\n"]
do_open $pD
set bD $::cur
file delete $pD
set ::answer_deleted no
set ::asked {}
check_stale_buffers
ok "drop: the user was asked"      [lindex [last_asked] 0] deleted
ok "drop: tab was closed"          [dict exists $::buffers $bD] 0

# --- a bulk change stales several tabs at once, in one round trip ------------

set p1 [mkfile "one\n"] ; set p2 [mkfile "two\n"] ; set p3 [mkfile "three\n"]
do_open $p1 ; set b1 $::cur
do_open $p2 ; set b2 $::cur
do_open $p3 ; set b3 $::cur
typ "EDIT "                 ;# b3 is the modified one
rewrite $p1 "one, changed\n" ; rewrite $p2 "two, changed\n" ; rewrite $p3 "three, changed\n"
set ::asked {}
set ::answer_changed no
check_stale_buffers
# The two clean ones reload silently; only the modified one is put to the user, and it is
# ONE dialog naming what it covers, not one per file.
ok "bulk: one prompt for the set"  [llength $::asked] 1
ok "bulk: prompt names the file"   [string match "*[file tail $p3]*" [lindex [last_asked] 1]] 1
activate $b1 ; ok "bulk: first reloaded"  [gtext] "one, changed\n"
activate $b2 ; ok "bulk: second reloaded" [gtext] "two, changed\n"
activate $b3 ; ok "bulk: modified kept"   [string match "EDIT *" [gtext]] 1
ok "bulk: nothing stale after"     [llength [dict get [rio_call buffers.stale {}] result stale]] 0

# Several modified files conflicting at once share ONE dialog, listing them.
foreach b [list $b1 $b2] { activate $b ; typ "X " }
rewrite $p1 "one again\n" ; rewrite $p2 "two again\n"
set ::asked {}
check_stale_buffers
ok "bulk: still one prompt"        [llength $::asked] 1
ok "bulk: prompt counts them"      [string match "2 open files*" [lindex [last_asked] 1]] 1
ok "bulk: lists both names"        [expr {[string match "*[file tail $p1]*" [lindex [last_asked] 1]]
	&& [string match "*[file tail $p2]*" [lindex [last_asked] 1]]}] 1

# --- a scratch buffer is never stale -----------------------------------------

do_new
set ::asked {}
check_stale_buffers
ok "scratch: nothing to ask about" [llength $::asked] 0

# --- a check landing mid-op defers instead of asking -------------------------
# The op in flight may be exactly what settles the buffer: fs_apply_delete closes the tab
# of the file it just deleted, right after the op returns. Asking first would report
# rio's own deliberate delete as a surprise.
set pF [mkfile "midop\n"]
do_open $pF
set bF $::cur
file delete $pF
set ::asked {}
set ::pending(fake) [clock milliseconds]      ;# pretend a call is in flight
check_stale_buffers
ok "midop: deferred, not asked"    [llength $::asked] 0
ok "midop: a retry is armed"       [expr {$::stale_retry ne ""}] 1
unset ::pending(fake)
after cancel $::stale_retry ; set ::stale_retry ""
set ::answer_deleted no ; check_stale_buffers  ;# now it asks, and we drop the tab
ok "midop: asked once the op ended" [lindex [last_asked] 0] deleted

# --- re-entrancy: a check that runs while a modal is up does not stack -------
# A modal runs the event loop, so a second trigger can arrive mid-prompt. The guard makes
# the inner call a no-op rather than a second stack of dialogs.
set pE [mkfile "outer\n"]
do_open $pE
set bE $::cur
typ "Y "
rewrite $pE "outer, changed\n"
set ::asked {}
proc stale_ask {q} { lappend ::asked [list changed $q] ; check_stale_buffers ; return no }
check_stale_buffers
ok "reentry: asked exactly once"   [llength $::asked] 1

puts ""
if {$::fails == 0} { puts "ALL CHECKS PASSED" } else { puts "$::fails CHECK(S) FAILED" }
exit [expr {$::fails > 0}]

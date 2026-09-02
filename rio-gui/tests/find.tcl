#!/usr/bin/env wish
#
# Headless test for Find/Replace (AGENTS.md D36): the find bar over the core's
# stateless search ops (buffer.find / buffer.matches / buffer.replace_all).
# Drives the real frontend procs (find_open, find_step, find_replace_one,
# find_replace_all, find_close) and inspects the focused group's widget. Like
# the smoke suite, it runs a core in THIS process behind a socket and attaches
# the GUI over the real channel.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/find.tcl

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
proc tmpbytes {bytes} {
	set f [file tempfile path]
	fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f
	return $path
}
proc seltext {t} { expr {[catch {$t get sel.first sel.last} s] ? "" : $s} }
proc selrange {t} { expr {[catch {list [$t index sel.first] [$t index sel.last]} r] ? "" : $r} }
proc needle {s} { .find.e delete 0 end ; .find.e insert 0 $s ; find_update }
proc repl   {s} { .find.re delete 0 end ; .find.re insert 0 $s }

# --- open a known buffer -------------------------------------------------------
set fileA [tmpbytes "alpha beta\nBETA gamma\nbeta end\n"]
do_open $fileA
set g $::focus
set t [gw $g]

# --- open/close, mode rows -----------------------------------------------------
ok "start: bar hidden"            [winfo manager .find] ""
find_open 0
ok "open: bar packed"             [winfo manager .find] pack
ok "open: replace row hidden"     [lindex [grid info .find.re] 0] ""
# (Focus itself is not asserted: a withdrawn window never takes Tk focus, so
# find_open/find_close's focus calls are untestable headless.)
find_open 1
ok "open+replace: replace row shown" [expr {[grid info .find.re] ne ""}] 1

# --- matches: count + paint (nocase default) -----------------------------------
needle beta
ok "update: three matches counted" [.find.count cget -text] "3 matches"
ok "update: three ranges painted"  [expr {[llength [$t tag ranges findmatch]] / 2}] 3
ok "update: first range right"     [lrange [$t tag ranges findmatch] 0 1] {1.6 1.10}

# --- find next: step, wrap, prev ------------------------------------------------
$t mark set insert 1.0
$t tag remove sel 1.0 end
find_next
ok "next: first match selected"    [selrange $t] {1.6 1.10}
ok "next: caret after the match"   [$t index insert] 1.10
ok "next: i of n"                  [.find.count cget -text] "1 of 3"
find_next
ok "next: nocase reaches BETA"     [selrange $t] {2.0 2.4}
find_next
ok "next: third match"             [selrange $t] {3.0 3.4}
find_next
ok "next: wraps to the first"      [selrange $t] {1.6 1.10}
ok "next: label says wrapped"      [.find.count cget -text] "1 of 3 · wrapped"
find_prev
ok "prev: steps back to the last"  [selrange $t] {3.0 3.4}

# --- match case ------------------------------------------------------------------
set ::find_case 1
find_update
ok "case: two exact matches"       [.find.count cget -text] "2 matches"
$t mark set insert 1.0
$t tag remove sel 1.0 end
find_next ; find_next
ok "case: skips BETA"              [selrange $t] {3.0 3.4}
set ::find_case 0
find_update

# --- no matches ------------------------------------------------------------------
needle zzz
ok "miss: counted as none"         [.find.count cget -text] "No matches"
ok "miss: nothing painted"         [$t tag ranges findmatch] ""

# --- replace one: two-step (select, then replace) --------------------------------
needle beta
repl X
$t mark set insert 1.0
$t tag remove sel 1.0 end
find_replace_one   ;# nothing selected yet: just selects the first match
ok "replace: first click selects"  [seltext $t] "beta"
ok "replace: text unchanged"       [$t get 1.0 1.10] "alpha beta"
find_replace_one   ;# selection IS the match: replaces, then steps
ok "replace: match replaced"       [$t get 1.0 "1.0 lineend"] "alpha X"
ok "replace: stepped to the next"  [seltext $t] "BETA"

# --- replace all: one op, one undo step ------------------------------------------
needle beta
repl Y
find_replace_all
ok "all: every match replaced"     [$t get 1.0 end-1c] "alpha X\nY gamma\nY end\n"
ok "all: label reports the count"  [.find.count cget -text] "Replaced 2"
ok "all: buffer marked modified"   [bufget $::cur modified] 1
do_undo
ok "all: ONE undo restores both"   [$t get 1.0 end-1c] "alpha X\nBETA gamma\nbeta end\n"

# --- live update: an edit while the bar is open recounts (coalesced) --------------
needle X
ok "live: one X counted"           [.find.count cget -text] "1 match"
[gget $g path] insert 1.0 "X "     ;# type through the proxy: a real edit
update ; update idletasks          ;# run the coalesced after-idle find_update
ok "live: recounted after edit"    [.find.count cget -text] "2 matches"

# --- close: paint cleared, editor refocused ---------------------------------------
find_close
ok "close: bar unpacked"           [winfo manager .find] ""
ok "close: paint cleared"          [$t tag ranges findmatch] ""

# --- F3 with the bar closed reopens it --------------------------------------------
find_next
ok "f3: reopens the bar"           [winfo manager .find] pack

# --- split: the bar acts on the focused group -------------------------------------
find_close
set fileB [tmpbytes "beta here\n"]
do_open $fileB
move_buffer_to_other $::cur $::focus   ;# split: fileB alone in the other group
set g2 $::focus
ok "split: two groups"             [llength $::groups] 2
find_open 0
needle beta
ok "split: counts the focused buffer" [.find.count cget -text] "1 match"
ok "split: paints the focused group"  [expr {[llength [[gw $g2] tag ranges findmatch]] / 2}] 1

puts ""
if {$::fails == 0} { puts "ALL CHECKS PASSED" } else { puts "$::fails CHECK(S) FAILED" }
exit [expr {$::fails > 0}]

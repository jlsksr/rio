#!/usr/bin/env wish
#
# Headless vi-mode test for rio-gui (AGENTS.md D38): the modal engine — state
# transitions and their chrome (block cursor, status segment), counts, motions,
# the operators d/c/y with motion targets and doubled forms, x/p/u/i/a/o/O,
# visual state, aborts, and a clean detach with an operator pending. Every edit
# is asserted through buf_text, i.e. through the proxy -> core -> echo path.
# Keys are fed to the real dispatcher (rio::modes::vi::key), the same proc the
# <KeyPress> binding calls. Needs a DISPLAY (Tk); shows no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/vi.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31)
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

# Feed printable keys to the dispatcher, one by one, exactly as the <KeyPress>
# binding would (keysym = char for printables, no modifiers).
proc press {keys} {
	set w [gget $::focus path]
	foreach ch [split $keys ""] { rio::modes::vi::key $w $ch $ch 0 }
}
proc esc {} { rio::modes::vi::key [gget $::focus path] Escape \x1b 0 }
proc vist {key} { rio::modes::vi::st $::focus $key }
proc caret {} { rio_real_t index insert }
proc load_text {txt {at 1.0}} {
	.ed.t delete 1.0 "end -1c"
	.ed.t insert insert $txt
	.ed.t mark set insert $at
}
proc typed {txt} { .ed.t insert insert $txt } ;# insert state = Tk editing

set ::edit_mode vi
apply_editmode

# --- states + chrome -----------------------------------------------------------
ok "vi: starts in normal"     [vist state] normal
ok "vi: block cursor"         [rio_real_t cget -blockcursor] 1
ok "vi: no status segment"    $::editmode_status ""
press i
ok "vi: i enters insert"      [vist state] insert
ok "vi: insert status"        $::editmode_status "-- INSERT --"
ok "vi: bar cursor"           [rio_real_t cget -blockcursor] 0
ok "vi: insert passes keys"   [rio::modes::vi::key [gget 0 path] x x 0] 0
esc
ok "vi: Esc back to normal"   [vist state] normal
ok "vi: status cleared"       $::editmode_status ""

# Esc steps the caret back (vi convention), unless at the line start
load_text "abc" 1.2
press i ; esc
ok "vi: Esc caret -1c"        [caret] 1.1

# --- motions + counts ----------------------------------------------------------
load_text "alpha beta gamma\nsecond line\nthird"
ok "vi: 3l"     [press 3l ; caret] 1.3
ok "vi: h"      [press h  ; caret] 1.2
ok "vi: 0"      [press 0  ; caret] 1.0
ok "vi: w"      [press w  ; caret] 1.6
ok "vi: 2w"     [press 0 ; press 2w ; caret] 1.11
ok "vi: b"      [press b  ; caret] 1.6
ok "vi: e"      [press e  ; caret] 1.9
ok "vi: dollar" [press 0 ; press {$} ; caret] 1.15
ok "vi: j"      [press 0 ; press j ; lindex [split [caret] .] 0] 2
ok "vi: k"      [press k ; lindex [split [caret] .] 0] 1
ok "vi: G"      [press G  ; caret] 3.0
ok "vi: gg"     [press gg ; caret] 1.0
ok "vi: 2G"     [press 2G ; caret] 2.0
ok "vi: 9G clamps" [press 9G ; caret] 3.0
ok "vi: h stops at linestart" [press gg ; press 5h ; caret] 1.0

# arrows are motions too
rio::modes::vi::key [gget 0 path] Right "" 0
ok "vi: Right = l"  [caret] 1.1
rio::modes::vi::key [gget 0 path] Down "" 0
ok "vi: Down = j"   [lindex [split [caret] .] 0] 2

# a Control combo is swallowed inertly in normal state (no motion, no edit)
press gg
set before [buf_text $::cur]
ok "vi: ctrl swallowed"       [rio::modes::vi::key [gget 0 path] k k 4] 1
ok "vi: ctrl moved nothing"   [caret] 1.0
ok "vi: ctrl edited nothing"  [buf_text $::cur] $before
# Prior/Next fall through to Tk's paging
ok "vi: Prior passes"         [rio::modes::vi::key [gget 0 path] Prior "" 0] 0

# --- x, u ------------------------------------------------------------------------
load_text "alpha beta"
press x
ok "vi: x deletes a char"     [buf_text $::cur] "lpha beta"
press 3x
ok "vi: 3x"                   [buf_text $::cur] "a beta"
press u ; press u
ok "vi: u undoes"             [buf_text $::cur] "alpha beta"
# xp swaps characters (x cuts to the clipboard)
load_text "ab"
press xp
ok "vi: xp swaps"             [buf_text $::cur] "ba"

# --- operators: dw, d$, d2w, cw, cc --------------------------------------------
load_text "alpha beta"
press dw
ok "vi: dw"                   [buf_text $::cur] "beta"
load_text "alpha beta" 1.6
press d\$
ok "vi: d\$"                  [buf_text $::cur] "alpha "
load_text "one two three four"
press d2w
ok "vi: d2w"                  [buf_text $::cur] "three four"
load_text "one two three four"
press 2dw
ok "vi: 2dw"                  [buf_text $::cur] "three four"
# dw on the last word stops at the line end (never eats the newline)
load_text "one two\nnext" 1.4
press dw
ok "vi: dw clamps at lineend" [buf_text $::cur] "one \nnext"
# cw acts like ce: change the word, keep the following space, land in insert
load_text "alpha beta"
press cw
ok "vi: cw removes the word"  [buf_text $::cur] " beta"
ok "vi: cw enters insert"     [vist state] insert
typed "X"
esc
ok "vi: cw then typing"       [buf_text $::cur] "X beta"
# cc clears the line's content but keeps the line
load_text "alpha\nbeta"
press cc
ok "vi: cc keeps the line"    [buf_text $::cur] "\nbeta"
ok "vi: cc enters insert"     [vist state] insert
esc

# --- dd / yy / p (linewise) ------------------------------------------------------
load_text "one\ntwo\nthree"
press dd
ok "vi: dd"                   [buf_text $::cur] "two\nthree"
ok "vi: dd clipboard"         [clipboard get] "one\n"
press p
ok "vi: dd p puts below"      [buf_text $::cur] "two\none\nthree"
ok "vi: p caret on put line"  [caret] 2.0
press u ; press u
ok "vi: undo undo restores"   [buf_text $::cur] "one\ntwo\nthree"
load_text "one\ntwo\nthree"
press 2dd
ok "vi: 2dd"                  [buf_text $::cur] "three"
# dd on the last line eats the preceding newline
load_text "one\ntwo" 2.0
press dd
ok "vi: dd last line"         [buf_text $::cur] "one"
ok "vi: dd last clipboard"    [clipboard get] "two\n"
press p
ok "vi: p below last line"    [buf_text $::cur] "one\ntwo"
ok "vi: p caret after last"   [caret] 2.0
# yy duplicates a line
load_text "one\ntwo"
press yyp
ok "vi: yy p duplicates"      [buf_text $::cur] "one\none\ntwo"

# --- p (charwise) ----------------------------------------------------------------
load_text "abc" 1.0
clipboard clear ; clipboard append "ZZ"
press p
ok "vi: charwise p after cursor" [buf_text $::cur] "aZZbc"
ok "vi: charwise p caret"        [caret] 1.2

# --- i a o O ----------------------------------------------------------------------
load_text "ab" 1.0
press a
ok "vi: a moves past char"    [caret] 1.1
typed "X"
esc
ok "vi: a then typing"        [buf_text $::cur] "aXb"
load_text "alpha" 1.2
press o
ok "vi: o opens below"        [buf_text $::cur] "alpha\n"
ok "vi: o caret on new line"  [caret] 2.0
ok "vi: o enters insert"      [vist state] insert
typed "below"
esc
ok "vi: o then typing"        [buf_text $::cur] "alpha\nbelow"
press O
ok "vi: O opens above"        [buf_text $::cur] "alpha\n\nbelow"
ok "vi: O caret on new line"  [caret] 2.0
esc

# --- visual state -------------------------------------------------------------
load_text "alpha" 1.0
press v
ok "vi: v enters visual"      [vist state] visual
ok "vi: visual status"        $::editmode_status "-- VISUAL --"
press 2l
ok "vi: visual stretch"       [rio_real_t get sel.first sel.last] "alp"
press d
ok "vi: visual d deletes"     [buf_text $::cur] "ha"
ok "vi: visual d to normal"   [vist state] normal
ok "vi: visual d clipboard"   [clipboard get] "alp"
load_text "abcde" 1.1
press vly
ok "vi: visual y clipboard"   [clipboard get] "bc"
ok "vi: visual y kept text"   [buf_text $::cur] "abcde"
ok "vi: visual y caret"       [caret] 1.1
press vlc
ok "vi: visual c deletes"     [buf_text $::cur] "ade"
ok "vi: visual c to insert"   [vist state] insert
esc
load_text "abc" 1.0
press v
esc
ok "vi: Esc leaves visual"    [vist state] normal
ok "vi: Esc clears sel"       [llength [rio_real_t tag ranges sel]] 0

# --- aborts ----------------------------------------------------------------------
load_text "alpha beta" 1.0
press d
ok "vi: operator pends"       [vist op] d
esc
press l
ok "vi: Esc aborts operator"  [buf_text $::cur] "alpha beta"
ok "vi: motion after abort"   [caret] 1.1
press d
press y
ok "vi: mismatched op aborts" [vist op] ""
ok "vi: nothing deleted"      [buf_text $::cur] "alpha beta"

# --- mode switch with a pending operator detaches cleanly -------------------------
press d
set ::edit_mode windows
apply_editmode
ok "detach: block cursor off" [rio_real_t cget -blockcursor] 0
ok "detach: status cleared"   $::editmode_status ""
set ::edit_mode vi
apply_editmode
ok "reattach: fresh state"    [vist state] normal
ok "reattach: no pending op"  [vist op] ""

# --- a split gets its own vi state -------------------------------------------------
split_editor
set g2 [lindex $::groups end]
focus_group $g2
press i
ok "split: group has own state" [vist state] insert
esc
focus_group 0
ok "split: first group normal"  [vist state] normal
unsplit_editor

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

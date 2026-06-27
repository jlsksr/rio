#!/usr/bin/env wish
#
# Headless smoke for rio-gui: sources the real frontend (window withdrawn) and
# drives its actions and the dumb-view proxy directly — no dialogs, no synthetic
# key events — checking that the widget, the core, and the bytes on disk all
# agree. Needs a DISPLAY (Tk), but never shows a window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/smoke.tcl

set ::env(RIO_GUI_HEADLESS) 1
set argv {}                ;# don't let the frontend treat our args as a file
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
proc diskbytes {path} {
	set f [open $path rb] ; set b [::read $f] ; close $f ; return $b
}
proc widget {} { ::rio_real_t get 1.0 end-1c }
# The buffer ids currently backed by tab widgets (frames are named .tabs.b$id).
proc tab_ids {} {
	set ids {}
	foreach w [winfo children .tabs] { lappend ids [string range [winfo name $w] 1 end] }
	return [lsort $ids]
}

# --- open an LF file ---------------------------------------------------------
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
# Opening from a fresh launch prunes the empty scratch buffer; the tab bar must
# not leave an orphan tab behind (regression: a stale × tab crashed on click).
ok "open: tabs match order"     [tab_ids]                [lsort $::order]
ok "open: path recorded"        [bufget $::cur path]     $p
ok "open: not modified"         [bufget $::cur modified] 0
ok "open: core has file text"   [rio::doc::text $::cur]  "alpha\nbeta\n"
ok "open: widget mirrors core"  [widget]                 "alpha\nbeta\n"
ok "open: encoding detected"    [dict get [bufget $::cur meta] encoding] utf-8

# --- edit through the dumb-view proxy, then save -----------------------------
.t insert 1.0 "X"
ok "edit: marked modified"      [bufget $::cur modified] 1
ok "edit: core updated"         [rio::doc::text $::cur]  "Xalpha\nbeta\n"
ok "edit: widget updated"       [widget]                 "Xalpha\nbeta\n"
do_save
ok "save: not modified"         [bufget $::cur modified] 0
ok "save: bytes on disk"        [diskbytes $p]           "Xalpha\nbeta\n"

# --- tricky characters survive the proxy (no %A breakage) --------------------
.t insert 1.0 "\{\"z"
ok "edit: braces/quotes intact" [string range [rio::doc::text $::cur] 0 2] "\{\"z"

# --- CRLF is preserved across open -> edit -> save ---------------------------
set q [tmpbytes "a\r\nb\r\n"]
do_open $q
ok "crlf: eol detected"         [dict get [bufget $::cur meta] eol] crlf
.t insert 1.0 ">"
do_save
ok "crlf: preserved on save"    [diskbytes $q]    ">a\r\nb\r\n"

# --- undo / redo through the frontend ----------------------------------------
# (core text is normalized to \n; CRLF only re-appears on save, checked above)
do_undo
ok "undo: edit reverted"        [rio::doc::text $::cur] "a\nb\n"
do_redo
ok "redo: edit reapplied"       [rio::doc::text $::cur] ">a\nb\n"

# --- multi-buffer / tabs -----------------------------------------------------
set start [llength $::order]
set f1 [tmpbytes "FILE ONE\n"]
set f2 [tmpbytes "FILE TWO\n"]
do_open $f1
set b1 $::cur
do_open $f2
set b2 $::cur
ok "tabs: two new buffers"      [llength $::order] [expr {$start + 2}]
ok "tabs: active is f2"         [bufget $::cur path] $f2
ok "tabs: distinct buffers"     [expr {$b1 ne $b2}] 1

# Edit each independently; switching must not bleed content across tabs.
.t insert 1.0 "2"                       ;# edit f2 (active)
activate $b1
.t insert 1.0 "1"                       ;# edit f1
ok "tabs: f1 holds its own edit" [rio::doc::text $b1] "1FILE ONE\n"
ok "tabs: f2 holds its own edit" [rio::doc::text $b2] "2FILE TWO\n"
ok "tabs: switch shows f1"       [widget]            "1FILE ONE\n"

# Reopening an already-open path switches rather than duplicating.
set n [llength $::order]
do_open $f2
ok "tabs: reopen switches"      [bufget $::cur path] $f2
ok "tabs: no duplicate tab"     [llength $::order] $n

# Closing a tab drops it from the core too.
set victim $::cur
do_save                                  ;# avoid the discard prompt
do_close
ok "tabs: closed tab gone"      [lsearch -exact $::order $victim] -1
ok "tabs: buffer freed in core" [rio::doc::exists $victim] 0

# --- error surfacing ---------------------------------------------------------
# A failed op must reach the user through report_error, never crash a caller
# that read `result` blindly (regression: an op on a vanished buffer threw
# `key "result" not known`). Override report_error to capture instead of popping
# a modal that would hang the headless run.
set ::captured {}
proc report_error {message {code ""}} { lappend ::captured [list $code $message] }
set ghost [rio::doc::new "ghost"]
rio::core::call buffer.close [dict create buffer $ghost]   ;# core drops it...
set ::cur $ghost                                           ;# ...but a view still points at it
set rc [catch {load_buffer} err]
ok "error: load_buffer didn't crash" $rc                            0
ok "error: failure reported once"    [llength $::captured]          1
ok "error: code is no_buffer"        [lindex $::captured 0 0]        no_buffer
activate $b1                                              ;# back to a live buffer

# --- file pane (project root + lazy fs.list navigator) -----------------------
# Build a throwaway tree, open it as the project folder, and drive the pane the
# way a double-click would (select a row, call nav_activate).
proc nav_labels {} {
	set out {}
	for {set i 0} {$i < [.dock.files.list size]} {incr i} { lappend out [.dock.files.list get $i] }
	return $out
}
proc nav_click {row} {
	.dock.files.list selection clear 0 end ; .dock.files.list selection set $row ; nav_activate
}

set tf [file tempfile tpath] ; close $tf
set proj [file join [file dirname $tpath] riogui-nav-[clock clicks]]
file mkdir [file join $proj sub]
set zf [open [file join $proj zeta.txt] w] ; puts -nonewline $zf "ZETA\n" ; close $zf

ok "pane: empty before folder open" [nav_labels] {{  Open a folder…}}
open_folder $proj
ok "pane: nav_dir is the root"   $::nav_dir              [file normalize $proj]
ok "pane: header is project name" [.dock.files.head cget -text] [file tail $proj]
ok "pane: dirs then files"        [nav_labels]           {sub/ {  zeta.txt}}

# Descend into the subdir (row 0 = sub/), then back up via "../".
nav_click 0
ok "pane: descended into sub"     $::nav_dir             [file normalize [file join $proj sub]]
ok "pane: subdir shows .. first"  [lindex [nav_labels] 0] "../"
nav_click 0
ok "pane: ascended to root"       $::nav_dir             [file normalize $proj]

# Activating a file row opens it in a tab (row 1 = zeta.txt, after sub/).
nav_click 1
ok "pane: file opened in a tab"   [bufget $::cur path]   [file join $proj zeta.txt]
ok "pane: opened file's text"     [rio::doc::text $::cur] "ZETA\n"
file delete -force $proj

# --- dock layout: switch panes and switch sides ------------------------------
proc dock_slaves {} { pack slaves .dock }
proc dock_shows {w} { expr {[lsearch -exact [dock_slaves] $w] >= 0} }

show_pane git
ok "dock: git pane shown"         [list [dock_shows .dock.git] [dock_shows .dock.files]] {1 0}
ok "dock: dock_pane is git"       $::dock_pane           git
show_pane files
ok "dock: files pane shown"       [list [dock_shows .dock.files] [dock_shows .dock.git]] {1 0}

ok "dock: default side is left"   [dict get [pack info .dock] -side] left
set ::dock_side right ; place_dock
ok "dock: moved to the right"     [dict get [pack info .dock] -side] right
ok "dock: editor still expands"   [dict get [pack info .t] -expand] 1
set ::dock_side left ; place_dock
ok "dock: back to the left"       [dict get [pack info .dock] -side] left

# --- git pane: branch + changed files + diff (needs git) ---------------------
if {![catch {exec git --version}]} {
	set gdir [file join [file dirname $tpath] riogui-git-[clock clicks]]
	file mkdir $gdir
	proc gitc {dir args} { exec git -C $dir -c user.email=t@e -c user.name=t {*}$args }
	gitc $gdir init -q ; gitc $gdir branch -M main
	set gf [open [file join $gdir a.txt] w] ; puts -nonewline $gf "one\n" ; close $gf
	gitc $gdir add a.txt ; gitc $gdir commit -q -m first
	set gf [open [file join $gdir a.txt] w] ; puts -nonewline $gf "one\ntwo\n" ; close $gf

	open_folder $gdir          ;# active pane is files; git refreshes when shown
	show_pane git
	ok "git: branch shown"        [.dock.git.hdr.branch cget -text] "⎇ main"
	ok "git: change listed"       [string match "* M a.txt" [.dock.git.list get 0]] 1
	.dock.git.list selection set 0 ; git_select
	ok "git: diff shows the edit"  [string match "*+two*" [.dock.git.diff get 1.0 end-1c]] 1

	# Refresh after staging clears the worktree change for that path.
	gitc $gdir add a.txt ; refresh_git
	ok "git: refresh sees staged"   [string match "M *a.txt" [.dock.git.list get 0]] 1
	file delete -force $gdir
} else {
	puts "SKIP  git pane checks (git not installed)"
}

# --- theme applier -----------------------------------------------------------
# The default theme (from the core's theme.get) drives the live widgets; named
# fonts exist, and switching re-applies colours live.
ok "theme: editor uses named font"   [::rio_real_t cget -font]             RioEditorFont
ok "theme: RioEditorFont created"    [expr {"RioEditorFont" in [font names]}] 1
ok "theme: default editor bg"        [::rio_real_t cget -background]        white
ok "theme: default status bg"        [.status cget -background]             "#dddddd"

do_theme solarized-dark
ok "theme: dark editor bg applied"   [::rio_real_t cget -background]        "#002b36"
ok "theme: dark cursor applied"      [::rio_real_t cget -insertbackground]  "#93a1a1"
ok "theme: dark status bg applied"   [.status cget -background]             "#073642"
ok "theme: dark tab bar applied"     [.tabs cget -background]               "#00212b"

do_theme default
ok "theme: switched back to default" [::rio_real_t cget -background]        white

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

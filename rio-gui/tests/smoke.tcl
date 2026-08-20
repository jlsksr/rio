#!/usr/bin/env wish
#
# Headless smoke for rio-gui: drives the real frontend (window withdrawn) and its
# dumb-view proxy directly — no dialogs, no synthetic key events — checking that the
# widget, the core, and the bytes on disk all agree. Needs a DISPLAY (Tk), but never
# shows a window.
#
# The GUI is always a client to an out-of-process core (D30), so we run a core in
# THIS process behind a socket and attach the GUI to it (::connect_to). That keeps
# the core's state inspectable here (rio::doc::text, rio::agent::*) while every GUI
# op still crosses the real channel — including the agent, which now lives in the
# core and is driven over the channel (D26/D30): turns stream back as broadcast
# agent.* events, and provider/key/policy are ops.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/smoke.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
set ::connect_to "127.0.0.1:$::port"
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
# The text painted on a buffer's tab handle (name + the ● unsaved dot, D27).
proc tab_label_text {id} { [gget $::focus tabs].b$id.l cget -text }
# The buffer ids currently backed by tab widgets in the focused group's strip
# (frames are named .eg<g>.tabs.b$id).
proc tab_ids {} {
	set ids {}
	foreach w [winfo children [gget $::focus tabs]] { lappend ids [string range [winfo name $w] 1 end] }
	return [lsort $ids]
}

# --- open an LF file ---------------------------------------------------------
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
# Opening from a fresh launch prunes the empty scratch buffer; the tab bar must
# not leave an orphan tab behind (regression: a stale × tab crashed on click).
ok "open: tabs match order"     [tab_ids]                [lsort [gorder $::focus]]
ok "open: path recorded"        [bufget $::cur path]     $p
ok "open: not modified"         [bufget $::cur modified] 0
ok "open: core has file text"   [rio::doc::text $::cur]  "alpha\nbeta\n"
ok "open: widget mirrors core"  [widget]                 "alpha\nbeta\n"
ok "open: encoding detected"    [dict get [bufget $::cur meta] encoding] utf-8

# --- edit through the dumb-view proxy, then save -----------------------------
.ed.t insert 1.0 "X"
ok "edit: marked modified"      [bufget $::cur modified] 1
ok "edit: tab shows ● dot"      [string match "*●*" [tab_label_text $::cur]] 1
ok "edit: core updated"         [rio::doc::text $::cur]  "Xalpha\nbeta\n"
ok "edit: widget updated"       [widget]                 "Xalpha\nbeta\n"
do_save
ok "save: not modified"         [bufget $::cur modified] 0
ok "save: tab dot cleared"      [string match "*●*" [tab_label_text $::cur]] 0
ok "save: bytes on disk"        [diskbytes $p]           "Xalpha\nbeta\n"

# --- tricky characters survive the proxy (no %A breakage) --------------------
.ed.t insert 1.0 "\{\"z"
ok "edit: braces/quotes intact" [string range [rio::doc::text $::cur] 0 2] "\{\"z"

# --- backspace through the proxy past a trailing-zero column -----------------
# Regression: the proxy's delete branch computed i2 inside an expr, which coerced
# a Tk index like "1.10" to the float 1.1 — so `.ed.t delete insert-1c` silently
# no-op'd at columns 10, 20, … (backspace "stopped working" mid-line). Run the
# exact body of Tk's <BackSpace> binding over a >20-char line; it must fully empty.
do_open [tmpbytes ""]
.ed.t insert 1.0 "abcdefghijklmnopqrstuvwxyz"      ;# crosses cols 10 and 20
.ed.t mark set insert end-1c
for {set i 0} {$i < 26} {incr i} {
	if {[.ed.t compare insert != 1.0]} { .ed.t delete insert-1c }
}
ok "backspace: empties past col 10/20" [rio::doc::text $::cur] ""
ok "backspace: widget mirrors empty"   [widget]               ""
# A range delete ending on a trailing-zero column must also fire.
.ed.t insert 1.0 "0123456789ABCDEF"
.ed.t delete 1.0 1.10
ok "delete: range to col 10 applied"   [rio::doc::text $::cur] "ABCDEF"
do_save ; do_close

# --- CRLF is preserved across open -> edit -> save ---------------------------
set q [tmpbytes "a\r\nb\r\n"]
do_open $q
ok "crlf: eol detected"         [dict get [bufget $::cur meta] eol] crlf
.ed.t insert 1.0 ">"
do_save
ok "crlf: preserved on save"    [diskbytes $q]    ">a\r\nb\r\n"

# --- undo / redo through the frontend ----------------------------------------
# (core text is normalized to \n; CRLF only re-appears on save, checked above)
do_undo
ok "undo: edit reverted"        [rio::doc::text $::cur] "a\nb\n"
do_redo
ok "redo: edit reapplied"       [rio::doc::text $::cur] ">a\nb\n"

# --- multi-buffer / tabs -----------------------------------------------------
set start [llength [gorder $::focus]]
set f1 [tmpbytes "FILE ONE\n"]
set f2 [tmpbytes "FILE TWO\n"]
do_open $f1
set b1 $::cur
do_open $f2
set b2 $::cur
ok "tabs: two new buffers"      [llength [gorder $::focus]] [expr {$start + 2}]
ok "tabs: active is f2"         [bufget $::cur path] $f2
ok "tabs: distinct buffers"     [expr {$b1 ne $b2}] 1

# Edit each independently; switching must not bleed content across tabs.
.ed.t insert 1.0 "2"                       ;# edit f2 (active)
activate $b1
.ed.t insert 1.0 "1"                       ;# edit f1
ok "tabs: f1 holds its own edit" [rio::doc::text $b1] "1FILE ONE\n"
ok "tabs: f2 holds its own edit" [rio::doc::text $b2] "2FILE TWO\n"
ok "tabs: switch shows f1"       [widget]            "1FILE ONE\n"

# Reopening an already-open path switches rather than duplicating.
set n [llength [gorder $::focus]]
do_open $f2
ok "tabs: reopen switches"      [bufget $::cur path] $f2
ok "tabs: no duplicate tab"     [llength [gorder $::focus]] $n

# Closing a tab drops it from the core too.
set victim $::cur
do_save                                  ;# avoid the discard prompt
do_close
ok "tabs: closed tab gone"      [lsearch -exact [gorder $::focus] $victim] -1
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
gset $::focus cur $ghost                                   ;# ...but a group still points at it
set rc [catch {load_buffer $::focus} err]
ok "error: load_buffer didn't crash" $rc                            0
ok "error: failure reported once"    [llength $::captured]          1
ok "error: code is no_buffer"        [lindex $::captured 0 0]        no_buffer
activate $b1                                              ;# back to a live buffer

# --- session.hello handshake (O2) ---------------------------------------------
# Startup greeted the core over the channel and recorded its protocol version; a
# core speaking a different version must warn (captured, since report_error is
# overridden above) rather than quietly misparse ops later.
ok "hello: core protocol recorded"   $::core_protocol $::rio_protocol
set ::captured {}
set ::rio_protocol 99 ; hello_core ; set ::rio_protocol 2
ok "hello: mismatch warned once"     [llength $::captured] 1
ok "hello: warning names versions"   \
	[string match "*protocol 2*expects 99*" [lindex $::captured 0 1]] 1
ok "hello: mismatch code"            [lindex $::captured 0 0] protocol_mismatch
set ::captured {}

# --- file pane (project root + lazy fs.list navigator) -----------------------
# Build a throwaway tree, open it as the project folder, and drive the pane the
# way a double-click would (select a row, call nav_activate).
# The pane is a read-only rl_* text widget (D42/D43): each row is
# "<flag-gutter:2><glyph> <name>", so a label is the line text past a 4-char prefix
# (the 2-char git-flag gutter, the type glyph, and its space).
proc nav_labels {} {
	set b .pfiles.well.body
	set out {}
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set L [expr {$i + 1}]
		lappend out [string range [$b get "$L.0" "$L.0 lineend"] 4 end]
	}
	return $out
}
proc nav_click {row} {
	rl_select .pfiles.well.body $row ; rl_activate .pfiles.well.body
}

set tf [file tempfile tpath] ; close $tf
set proj [file join [file dirname $tpath] riogui-nav-[clock clicks]]
file mkdir [file join $proj sub]
set zf [open [file join $proj zeta.txt] w] ; puts -nonewline $zf "ZETA\n" ; close $zf

ok "pane: empty before folder open" [nav_labels] {{Open a folder…}}
open_folder $proj
ok "pane: nav_dir is the root"   $::nav_dir              [file normalize $proj]
ok "pane: header is project name" [.pfiles.hdr.head cget -text] [file tail $proj]
ok "pane: dirs then files"        [nav_labels]           {sub/ zeta.txt}
# Bands: a selection covers exactly its row (through the newline, so it spans full
# width); a hover tags the hovered row. (D42 rich-list.)
rl_select .pfiles.well.body 0
ok "pane: selection band on row 0" [.pfiles.well.body tag ranges selrow]   {1.0 2.0}
rl_set_hover .pfiles.well.body 1
ok "pane: hover band on row 1"     [.pfiles.well.body tag ranges hoverrow] {2.0 3.0}
update idletasks
ok "pane: scrollbar hidden when list fits" \
	[expr {[lsearch -exact [pack slaves .pfiles.well] .pfiles.well.sb] < 0}] 1

# Descend into the subdir (row 0 = sub/), then back up via "..".
nav_click 0
ok "pane: descended into sub"     $::nav_dir             [file normalize [file join $proj sub]]
ok "pane: subdir shows .. first"  [lindex [nav_labels] 0] ".."
nav_click 0
ok "pane: ascended to root"       $::nav_dir             [file normalize $proj]

# fs.changed repaints the files pane when the write lands in the shown directory, so an
# agent-created file appears without a manual reload (D47). Create a file on disk behind
# the pane's back, then feed it the event the core would broadcast.
set nf [open [file join $proj gamma.txt] w] ; puts -nonewline $nf "G\n" ; close $nf
ok "pane: new file absent pre-event"   [expr {[lsearch -exact [nav_labels] gamma.txt] >= 0}] 0
dispatch_event [dict create event fs.changed params [dict create path [file join $proj gamma.txt]]]
ok "pane: fs.changed reveals new file" [expr {[lsearch -exact [nav_labels] gamma.txt] >= 0}] 1
# A write OUTSIDE the shown directory does not repaint it (single-dir navigator): create
# delta.txt in the root but signal a change under sub/ — the guard skips the repaint, so
# delta.txt must stay hidden until something legitimately refreshes.
set df [open [file join $proj delta.txt] w] ; puts -nonewline $df "D\n" ; close $df
dispatch_event [dict create event fs.changed params [dict create path [file join $proj sub deep.txt]]]
ok "pane: out-of-dir change skips repaint" [expr {[lsearch -exact [nav_labels] delta.txt] >= 0}] 0
# The ⟳ refresh control reloads the shown directory on demand — the manual path for
# changes rio didn't make. delta.txt is on disk in the root but not yet shown (the
# out-of-dir event above skipped its repaint); running the control's action reveals it.
ok "pane: refresh control wired"   [bind .pfiles.hdr.refresh <Button-1>] populate_nav
uplevel #0 [bind .pfiles.hdr.refresh <Button-1>]
ok "pane: refresh reloads the dir" [expr {[lsearch -exact [nav_labels] delta.txt] >= 0}] 1
file delete [file join $proj delta.txt]

# Regaining OS focus re-syncs the dock (note_app_focus's false→true edge), so a file
# created while rio was in the background shows on return. Drive the testable core
# directly: mark unfocused, create epsilon.txt behind the pane's back, then mark focused.
note_app_focus 0
set ef [open [file join $proj epsilon.txt] w] ; puts -nonewline $ef "E\n" ; close $ef
ok "pane: focus-return absent first" [expr {[lsearch -exact [nav_labels] epsilon.txt] >= 0}] 0
note_app_focus 1
ok "pane: focus-return reveals file"  [expr {[lsearch -exact [nav_labels] epsilon.txt] >= 0}] 1
# A no-op re-focus (already focused) does not spuriously reload: delete on disk, re-mark
# focused, and the stale row is still shown (no refresh fired on the true→true no-edge).
file delete [file join $proj epsilon.txt]
note_app_focus 1
ok "pane: no reload without an edge"  [expr {[lsearch -exact [nav_labels] epsilon.txt] >= 0}] 1
# Restore the original tree ({sub/ zeta.txt}) for the row-index tests that follow.
file delete [file join $proj gamma.txt] ; populate_nav

# Activating a file row opens it in a tab (row 1 = zeta.txt, after sub/).
nav_click 1
ok "pane: file opened in a tab"   [bufget $::cur path]   [file join $proj zeta.txt]
ok "pane: opened file's text"     [rio::doc::text $::cur] "ZETA\n"

# --- file-management context actions (D48) -----------------------------------
# The verbs sit between Copy Path and any git items; with no repo here the row menu is
# just Open/Copy Path + the four fs verbs. On the shown dir's own entry all four appear;
# on a ".." row (a dir whose parent is NOT the shown dir) only New File/New Folder do,
# never Rename/Delete of the parent.
proc menu_labels2 {m} {
	set out {}
	for {set i 0} {$i <= [$m index end]} {incr i} {
		lappend out [expr {[$m type $i] eq "separator" ? "---" : [$m entrycget $i -label]}]
	}
	return $out
}
menu .fsm -tearoff 0
nav_menu_build .fsm [list file [file join $proj zeta.txt]]
ok "fs-menu: file row has all four verbs" [menu_labels2 .fsm] \
	[list Open {Copy Path} --- {New File…} {New Folder…} Rename… Delete…]
.fsm delete 0 end ; nav_menu_build .fsm [list dir [file dirname $proj]]
ok "fs-menu: .. row omits Rename/Delete" [menu_labels2 .fsm] [list Open --- {New File…} {New Folder…}]
destroy .fsm

# fs_apply_create writes through the core and the pane shows it after a repaint.
fs_apply_create file kappa.txt
ok "fs: created file on disk"   [file isfile [file join $proj kappa.txt]] 1
ok "fs: created file in pane"   [expr {[lsearch -exact [nav_labels] kappa.txt] >= 0}] 1
fs_apply_create dir newdir
ok "fs: created folder on disk" [file isdirectory [file join $proj newdir]] 1
ok "fs: created folder in pane" [expr {[lsearch -exact [nav_labels] newdir/] >= 0}] 1
# An invalid (non-single-component) name is refused: nothing created, no crash.
fs_apply_create file "a/b.txt"
ok "fs: nested name refused"    [file exists [file join $proj a]] 0

# Rename a file that is open in a tab: disk renamed AND the tab retargets (path + title).
do_open [file join $proj kappa.txt]
fs_apply_rename [file join $proj kappa.txt] lambda.txt
ok "fs: rename moved on disk"   [list [file exists [file join $proj kappa.txt]] \
	[file isfile [file join $proj lambda.txt]]] {0 1}
ok "fs: open tab retargeted"    [bufget $::cur path]   [file join $proj lambda.txt]
ok "fs: tab title follows"      [tab_name $::cur]      lambda.txt

# Delete a file open in a tab: disk gone and the buffer closes (no save prompt — the
# modified flag is cleared first). Buffer count drops by one.
set before [dict size $::buffers]
fs_apply_delete [file join $proj lambda.txt]
ok "fs: deleted file on disk"   [file exists [file join $proj lambda.txt]] 0
ok "fs: open tab closed"        [dict size $::buffers] [expr {$before - 1}]

file delete -force $proj

# --- dock sites (D35 c1b): host tab strips, pane switch, side switch ----------
proc body_in {site} { pack slaves .site$site.body }         ;# the active body there
proc site_shows {site w} { expr {[lsearch -exact [body_in $site] $w] >= 0} }
proc tabs_of {site} { lmap t [winfo children .site$site.tabs] { winfo name $t } }

show_pane git
ok "dock: git body shown"         [list [site_shows left .pgit] [site_shows left .pfiles]] {1 0}
ok "dock: dock_pane is git"       $::dock_pane           git
ok "dock: tab strip lists both"   [lsort [tabs_of left]] {files git}
ok "dock: git tab highlighted"    [.siteleft.tabs.git cget -background]   [dict get $::theme_colors tab.active.bg]
ok "dock: files tab recedes"      [.siteleft.tabs.files cget -background] [dict get $::theme_colors tab.inactive.bg]
show_pane files
ok "dock: files body shown"       [list [site_shows left .pfiles] [site_shows left .pgit]] {1 0}

# The left site keeps a stable width (propagate off) regardless of which pane shows —
# otherwise the git diff (editor font) would balloon the whole window on switch.
show_pane files ; set wf [.siteleft cget -width]
show_pane git   ; set wg [.siteleft cget -width]
ok "dock: width stable on switch"  [expr {$wf == $wg}] 1
show_pane files

# A tab click activates that panel, same as show_pane.
site_tab_click left git
ok "dock: tab click activates"    $::dock_pane git
site_tab_click left files

ok "dock: left site on left"      [dict get [pack info .siteleft] -side] left
dock_set_side right
ok "dock: dock moved to right"    [expr {[site_shows right .pfiles] && [dict get [pack info .siteright] -side] eq "right"}] 1
ok "dock: left site emptied"      [rio::layout::get left panels] {}
ok "dock: mirror side follows"    $::dock_side right
ok "dock: editor still expands"   [dict get [pack info .groups] -expand] 1
dock_set_side left
ok "dock: back on the left"       [dict get [pack info .siteleft] -side] left

# The sash sits between the left site and the editor; a drag clamps its width.
ok "sash: parked on left edge"    [dict get [pack info .sash] -side] left
.siteleft configure -width 40 ; sash_drag   ;# pointer not over sash -> clamps to min
ok "sash: clamps to minimum width" [expr {[.siteleft cget -width] >= 120}] 1

# --- editor scrollbars + line wrapping ---------------------------------------
# The vertical bar is driven through edscroll (which sets .eg0.vsb and repaints the
# gutter, D49); the horizontal bar auto-hides (gridscroll) when no line overflows, and
# wrapping drops it (no h-scroll wrapped). The auto-hide logic is driven directly with
# fractions: in a withdrawn window the text never reports real overflow, so we can't
# lean on live geometry here.
proc hsb_shown {} { expr {[lsearch -exact [grid slaves .eg0] .eg0.hsb] >= 0} }
ok "editor: vsb wired via edscroll" [::rio_real_t cget -yscrollcommand] {edscroll 0}
ok "editor: hsb auto-hides"      [::rio_real_t cget -xscrollcommand] {gridscroll .eg0.hsb}
ok "editor: default no wrap"     [::rio_real_t cget -wrap]           none
gridscroll .eg0.hsb 0.0 0.5 ; ok "editor: hsb shown when a line overflows" [hsb_shown] 1
gridscroll .eg0.hsb 0.0 1.0 ; ok "editor: hsb hidden when text fits"       [hsb_shown] 0
# Re-show it, then wrapping must hide it regardless.
gridscroll .eg0.hsb 0.0 0.5
set ::wrap_lines 1 ; apply_wrap
ok "editor: wrap word applied"        [::rio_real_t cget -wrap] word
ok "editor: hsb hidden when wrapping" [hsb_shown] 0
set ::wrap_lines 0 ; apply_wrap
ok "editor: wrap off restores no-wrap" [::rio_real_t cget -wrap] none

# --- line-number gutter (D49) ------------------------------------------------
# The gutter is a canvas in column 0, gridded while ::line_numbers is on, its width
# sized to the last line's digit count (min two). The numbers themselves come from
# dlineinfo, which needs a mapped window, so a withdrawn smoke can't assert the
# painted glyphs — it checks the state, the grid slot, and the digit-driven width.
ok "gutter: default on"          $::line_numbers                      1
ok "gutter: canvas exists"       [winfo class .eg0.gutter]            Canvas
ok "gutter: gridded when on"     [expr {[llength [grid info .eg0.gutter]] > 0}] 1
ok "gutter: in column 0"         [dict get [grid info .eg0.gutter] -column]     0
set cw [font measure RioEditorFont 0]
set p2 [tmpbytes "a\nb\nc\n"]              ;# 3 lines → 2 digits (the floor)
do_open $p2 ; gutter_redraw $::focus
ok "gutter: width floors at two digits" [.eg0.gutter cget -width] [expr {2 * $cw + 12}]
set big "" ; for {set i 1} {$i <= 120} {incr i} { append big "line $i\n" }
set p3 [tmpbytes $big]                     ;# 120 lines → 3 digits, wider
do_open $p3 ; gutter_redraw $::focus
ok "gutter: width grows with digits"    [.eg0.gutter cget -width] [expr {3 * $cw + 12}]
# Toggling off grid-removes the canvas (its cell config is kept); back on re-grids it.
set ::line_numbers 0 ; apply_line_numbers
ok "gutter: removed when off"    [llength [grid info .eg0.gutter]]    0
set ::line_numbers 1 ; apply_line_numbers
ok "gutter: re-gridded when on"  [expr {[llength [grid info .eg0.gutter]] > 0}] 1
# Persisted like the other view toggles (prefs_load reads back what prefs_save wrote).
set ::line_numbers 0 ; prefs_save ; set ::line_numbers 1 ; prefs_load
ok "gutter: pref round-trips"    $::line_numbers                      0
set ::line_numbers 1 ; apply_line_numbers ; prefs_save   ;# restore the default for later tests
do_close ; do_close                                      ;# close the two temp buffers

# --- cursor position in the status bar ---------------------------------------
# refresh_status carries a compact "Ln L, Col C" segment for the focused group's
# insert mark; a cursor move (cursor_moved on the focused group) repaints it. Col is
# char+1 (Tk indexes from 0). No focus / no group -> "" rather than an error.
set pc [tmpbytes "one\ntwo three\nfour\n"]
do_open $pc
[fgw] mark set insert 2.4 ; cursor_moved $::focus
ok "cursor: segment reads Ln/Col"   [cursor_status]                       "Ln 2, Col 5"
ok "cursor: status bar shows it"    [expr {[string match {*Ln 2, Col 5*} [.status cget -text]]}] 1
[fgw] mark set insert 1.0 ; cursor_moved $::focus
ok "cursor: column is 1-based"      [cursor_status]                       "Ln 1, Col 1"
do_close                                                 ;# close the temp buffer

# --- git pane: branch + changed files + diff ---------------------------------
if {![catch {exec git --version}]} {
	set gdir [file join [file dirname $tpath] riogui-git-[clock clicks]]
	file mkdir $gdir
	proc gitc {dir args} { exec git -C $dir -c user.email=t@e -c user.name=t {*}$args }
	gitc $gdir init -q ; gitc $gdir branch -M main
	# Persist a local identity so git.commit (a plain `git commit`) works headless
	# regardless of the machine's global git config.
	gitc $gdir config user.email t@e ; gitc $gdir config user.name t
	set gf [open [file join $gdir a.txt] w] ; puts -nonewline $gf "one\n" ; close $gf
	set gf [open [file join $gdir b.txt] w] ; puts -nonewline $gf "bee\n" ; close $gf
	gitc $gdir add a.txt b.txt ; gitc $gdir commit -q -m first
	set gf [open [file join $gdir a.txt] w] ; puts -nonewline $gf "one\ntwo\n" ; close $gf
	file mkdir [file join $gdir sub]
	set nf [open [file join $gdir sub n.txt] w] ; puts -nonewline $nf "new\n" ; close $nf
	set uf [open [file join $gdir u.txt] w] ; puts -nonewline $uf "untracked\n" ; close $uf

	# The file pane annotates its rows with git flags (D43): with a.txt modified in the
	# worktree and an untracked file under sub/, the file pane (still the active pane
	# after open_folder) shows an "M" flag on the file and a "·" rollup dot on the dir.
	# (Look up by name — the pane also lists .git/, so row order isn't fixed.)
	proc fpane_flag {name} {
		set b .pfiles.well.body
		for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
			if {[file tail [lindex [rl_payload $b $i] 1]] eq $name} {
				set L [expr {$i + 1}]
				return [string index [$b get "$L.0" "$L.0 lineend"] 0]
			}
		}
		return ""
	}
	open_folder $gdir
	ok "pane: dir rollup dot on sub"     [fpane_flag sub]   "·"
	ok "pane: git flag on modified file" [fpane_flag a.txt] M
	ok "pane: untracked file flagged ?"  [fpane_flag u.txt] ?

	# Saving from the editor repaints the pane so a fresh flag appears (D43): b.txt is
	# committed-clean, so it has no flag until we edit it and save (do_save -> refresh).
	ok "pane: clean file has no flag"    [fpane_flag b.txt] " "
	do_open [file join $gdir b.txt]
	.ed.t insert 1.0 "z"
	do_save
	ok "pane: flag appears after save"   [fpane_flag b.txt] M

	# The git list is an rl_* rich-list too now (D43): a row is "<XY> <path>" in the
	# body text widget, picked via rl_select (which fires git_pick).
	proc git_line {row} {
		set b .pgit.well.body ; set L [expr {$row + 1}]
		return [$b get "$L.0" "$L.0 lineend"]
	}
	show_pane git              ;# the file pane was active above; git refreshes on show
	proc git_shows_diff {} { expr {[lsearch -exact [pack slaves .pgit] .pgit.diff] >= 0} }
	ok "git: branch shown"        [.pgit.hdr.branch cget -text] "⎇ main"
	ok "git: change listed"       [string match "* M a.txt" [git_line 0]] 1
	ok "git: diff hidden until pick" [git_shows_diff] 0
	rl_select .pgit.well.body 0
	ok "git: diff shows on pick"   [git_shows_diff] 1
	ok "git: diff shows the edit"  [string match "*+two*" [.pgit.diff get 1.0 end-1c]] 1

	# Context menus (D44). Build the menus without posting (tk_popup would grab) and
	# read back their entry labels; ::nav_git still reflects the last file-pane paint
	# (a.txt " M", u.txt "??", sub "??").
	proc menu_labels {m} {
		set out {}
		for {set i 0} {$i <= [$m index end]} {incr i} {
			lappend out [expr {[$m type $i] eq "separator" ? "---" : [$m entrycget $i -label]}]
		}
		return $out
	}
	# The file-management verbs (D48) sit between Copy Path and the git items; with the
	# folder open, a real entry OF the shown dir carries all four (New File/Folder,
	# Rename, Delete), so they precede the git tail here.
	set fsv {{New File…} {New Folder…} {Rename…} {Delete…}}
	menu .tm -tearoff 0
	nav_menu_build .tm [list file [file join $gdir a.txt]]
	ok "menu: modified file offers Stage" [menu_labels .tm] [list Open {Copy Path} --- {*}$fsv --- Stage]
	.tm delete 0 end ; nav_menu_build .tm [list file [file join $gdir u.txt]]
	ok "menu: untracked file offers Track" [menu_labels .tm] [list Open {Copy Path} --- {*}$fsv --- {Track (git add)}]
	.tm delete 0 end ; nav_menu_build .tm [list dir [file join $gdir sub]]
	ok "menu: dir with changes offers Stage folder" [menu_labels .tm] [list Open --- {*}$fsv --- {Stage folder}]
	.tm delete 0 end ; git_menu_build .tm [dict create x { } y M path a.txt]
	ok "menu: git unstaged offers Stage" [menu_labels .tm] {Open {Copy Path} --- Stage}
	.tm delete 0 end ; git_menu_build .tm [dict create x A y { } path c.txt]
	ok "menu: git staged offers Unstage" [menu_labels .tm] {Open {Copy Path} --- Unstage}
	destroy .tm

	# The action proc: stage/unstage a path through the core, then the pane repaints.
	# git_xy_for reads a path's two status chars back out of the git list.
	proc git_xy_for {name} {
		set b .pgit.well.body
		for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
			set p [rl_payload $b $i]
			if {$p ne "" && [dict get $p path] eq $name} {
				set L [expr {$i + 1}]
				return [string range [$b get "$L.0" "$L.0 lineend"] 0 1]
			}
		}
		return ""
	}
	do_git add [file join $gdir b.txt]
	ok "action: stage flips b.txt to staged"   [git_xy_for b.txt] "M "
	do_git unstage [file join $gdir b.txt]
	ok "action: unstage returns b.txt"          [git_xy_for b.txt] " M"

	# Refresh after staging clears the worktree change for that path and re-collapses.
	gitc $gdir add a.txt ; refresh_git
	ok "git: refresh sees staged"   [string match "M *a.txt" [git_line 0]] 1
	ok "git: diff re-collapses"     [git_shows_diff] 0

	# The commit bar (D45) auto-shows only when the index has a staged change. a.txt is
	# now staged (M ) from the refresh above, so the bar is packed into the git pane.
	proc git_bar_shown {} { expr {[lsearch -exact [pack slaves .pgit] .pgit.commit] >= 0} }
	ok "commit: bar shown when staged" [git_bar_shown] 1
	# The greyed "message" hint shows while the entry is empty and hides once text is typed.
	proc git_hint_shown {} { expr {[place info .pgit.commit.msg.ph] ne ""} }
	.pgit.commit.msg delete 0 end
	ok "commit: hint shown when empty" [git_hint_shown] 1
	.pgit.commit.msg insert 0 "x"
	ok "commit: hint hidden when typed" [git_hint_shown] 0
	.pgit.commit.msg delete 0 end
	ok "commit: hint back when cleared" [git_hint_shown] 1
	# An empty (whitespace) summary is refused without touching the repo: still staged.
	.pgit.commit.msg delete 0 end ; .pgit.commit.msg insert 0 "   " ; git_commit
	ok "commit: empty message no-ops"  [git_xy_for a.txt] "M "
	# A real summary commits the index: a.txt leaves the change list, the entry clears,
	# and with nothing staged left the bar auto-hides (b.txt/u.txt stay unstaged).
	.pgit.commit.msg delete 0 end ; .pgit.commit.msg insert 0 "smoke commit" ; git_commit
	ok "commit: staged change committed" [git_xy_for a.txt] ""
	ok "commit: entry cleared"           [.pgit.commit.msg get] ""
	ok "commit: bar hidden after commit" [git_bar_shown] 0
	after cancel refresh_git   ;# drop the pending git_flash restore before teardown
	file delete -force $gdir
} else {
	puts "SKIP  git pane checks (git not installed)"
}

# --- Search panel (D52) ------------------------------------------------------
# Three scopes on two core engines: Project walks the open project on disk
# (project.search), Open docs / Current doc walk the open buffers' live text
# (buffers.search). The GUI paints one grouped result list and goes to a row's
# location (a disk file OR an open buffer tab). A dedicated fixture (a needle across
# two files + a subdir + a .git/ dir the core must skip), independent of git. Each
# file also carries a unique `zztok` token so the buffer-scope counts are
# deterministic whatever else is open.
set fdir [file join [file dirname $tpath] riogui-search-[clock clicks]]
file mkdir [file join $fdir src] ; file mkdir [file join $fdir .git]
set ff [open [file join $fdir a.txt] w]  ; puts -nonewline $ff "alpha needle\nplain zztok\nneedle needle\n" ; close $ff
set ff [open [file join $fdir src b.txt] w] ; puts -nonewline $ff "a NEEDLE here\n" ; close $ff
set ff [open [file join $fdir c.txt] w] ; puts -nonewline $ff "needleworks\nplain needle here zztok zztok\n" ; close $ff
set ff [open [file join $fdir .git config] w] ; puts -nonewline $ff "needle skip me\n" ; close $ff
open_folder $fdir
# Panel widgets exist and start hidden; search_open packs the strip and focuses entry.
ok "search: panel canvas exists"     [winfo class .results.well.body]     Text
ok "search: hidden at boot"          $::search_shown                      0
ok "search: default scope current doc" $::search_scope                    "Current doc"
ok "search: label reads Search"      [.results.hdr.l cget -text]          "Search:"
proc search_packed {} { expr {[lsearch -exact [pack slaves .sitebottom.body] .results] >= 0} }
# Controls are bottom-anchored like the Agent composer (compose-pane rule, D35): the
# query row hugs the bottom edge, the results well fills above it.
ok "search: query row bottom-anchored" [dict get [pack info .results.hdr] -side]  bottom
ok "search: results well fills top"    [dict get [pack info .results.well] -side]  top
search_open
ok "search: open shows the panel"    [search_packed]                      1
# --- Project scope (the on-disk tree; the D51 find-in-files behaviour) ---
set ::search_scope "Project"
# Case-sensitive substring: a.txt (lines 1,3 = 3 hits) + c.txt (needleWORKS, needle = 2);
# src/b.txt's "NEEDLE" is excluded by case. Five hits across two files.
set ::search_case 1 ; set ::search_word 0
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 needle ; search_run
proc search_rowtext {i} { set L [expr {$i + 1}] ; .results.well.body get "$L.0" "$L.0 lineend" }
ok "search: project case-sensitive count" [.results.hdr.count cget -text] "5 matches · 2 files"
ok "search: file header row 0"       [string trim [search_rowtext 0]]     a.txt
ok "search: header row not selectable" [rl_selectable .results.well.body 0] 0
ok "search: match row selectable"    [rl_selectable .results.well.body 1] 1
ok "search: match row payload line"  [dict get [rl_payload .results.well.body 1] line] 1
ok "search: project row carries a path" [dict exists [rl_payload .results.well.body 1] path] 1
# The match is highlighted (fimatch band): row 1's "needle" starts at line-col 7, so
# after the "      1  " 9-char prefix the span is widget cols 15..21 on text line 2.
ok "search: first match highlighted" [lrange [.results.well.body tag ranges fimatch] 0 1] {2.15 2.21}
# Whole word drops the embedded hit in "needleworks" (c.txt row 1) — four hits left.
set ::search_word 1 ; search_run
ok "search: whole-word excludes needleworks" [.results.hdr.count cget -text] "4 matches · 2 files"
set ::search_word 0
# Case-insensitive: now src/b.txt matches too — six hits across three files.
set ::search_case 0 ; search_run
ok "search: nocase spans three files" [.results.hdr.count cget -text]     "6 matches · 3 files"
# Activating a project (disk) row opens the file and jumps to the matched line.
search_activate [dict create path [file join $fdir a.txt] line 3 col 1]
ok "search: activate opened the disk file" [file tail [bufget $::cur path]] a.txt
ok "search: caret jumped to the line" [lindex [split [[fgw] index insert] .] 0] 3
set abuf $::cur                                ;# the a.txt buffer, now open
# --- Current doc scope (buffers.search, only the focused buffer) ---
do_open [file join $fdir c.txt] ; set cbuf $::cur
set ::search_scope "Current doc" ; set ::search_case 1
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 needle ; search_run
ok "search: current-doc counts the focused buffer" [.results.hdr.count cget -text] "2 matches · 1 buffer"
ok "search: current-doc row carries a buffer id" [dict exists [rl_payload .results.well.body 1] buffer] 1
# --- Open docs scope (every open buffer) ---
# The unique zztok token lives only in the two fixture buffers (a.txt once, c.txt
# twice), so the count is deterministic: three hits across two buffers.
set ::search_scope "Open docs"
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 zztok ; search_run
ok "search: open-docs spans open buffers" [.results.hdr.count cget -text] "3 matches · 2 buffers"
# Activating a buffer row switches to that tab and jumps — focus a.txt first, then
# activate c.txt's row.
activate $abuf
ok "search: focused a different buffer" [expr {$::cur ne $cbuf}]          1
search_activate [dict create buffer $cbuf line 2 col 1]
ok "search: activate switched to the buffer tab" [expr {$::cur eq $cbuf}] 1
ok "search: activate jumped to the buffer line" [lindex [split [[fgw] index insert] .] 0] 2
# --- Escalate from the find bar: seed needle + options, widen to Project ---
find_open 0
.find.e delete 0 end ; .find.e insert 0 alpha ; set ::find_case 1 ; set ::find_word 0
search_from_bar
ok "search: bar handoff seeds the needle" [.results.hdr.e get]           alpha
ok "search: bar handoff widens to Project" $::search_scope               "Project"
ok "search: bar handoff carries Match case" $::search_case               1
find_close
# Empty needle clears the list and the count.
set ::search_case 0
.results.hdr.e delete 0 end ; search_run
ok "search: empty needle clears"     [.results.hdr.count cget -text]      ""
ok "search: empty needle empties list" [llength $::rl_rows(.results.well.body)] 0
search_close
ok "search: close hides the panel"   [search_packed]                      0
# Close the two fixture buffers this block opened (neither was edited, so no prompt).
activate $abuf ; do_close
activate $cbuf ; do_close
file delete -force $fdir

# --- Search panel: Replace (D52 Phase B) -------------------------------------
# Buffer scopes replace through buffer.replace_all (undoable, unsaved); Project
# replace is confirm-gated and rewrites CLOSED files on disk (open files go through
# their buffers). A distinctive token (zqcat) keeps the Open-docs count deterministic.
set rdir [file join [file dirname $tpath] riogui-repl-[clock clicks]]
file mkdir $rdir
set ff [open [file join $rdir p.txt] w] ; puts -nonewline $ff "zqcat and zqcat\n" ; close $ff
set ff [open [file join $rdir q.txt] w] ; puts -nonewline $ff "one zqcat two\n" ; close $ff
set ff [open [file join $rdir r.txt] w] ; puts -nonewline $ff "red red\n" ; close $ff
open_folder $rdir
search_open
# The replace row toggles with Ctrl+H (search_show_replace).
proc rep_packed {} { expr {[lsearch -exact [pack slaves .results] .results.rep] >= 0} }
ok "replace: row hidden by default"  [rep_packed]                         0
search_show_replace 1
ok "replace: Ctrl+H shows the row"   [rep_packed]                         1
ok "replace: row sits above the query" [dict get [pack info .results.rep] -side] bottom
# Open two buffers, both carrying zqcat.
do_open [file join $rdir p.txt] ; set pbuf $::cur
do_open [file join $rdir q.txt] ; set qbuf $::cur
# Open docs: replace zqcat -> ZQ across both buffers (3 hits, 2 buffers).
set ::search_scope "Open docs" ; set ::search_case 1 ; set ::search_word 0
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 zqcat
.results.rep.e delete 0 end ; .results.rep.e insert 0 ZQ
search_replace_all
ok "replace: open-docs edited both buffers" [list [buf_text $pbuf] [buf_text $qbuf]] \
	[list "ZQ and ZQ\n" "one ZQ two\n"]
ok "replace: open-docs count message" [string match "Replaced 3 * 2 buffers" [.results.hdr.count cget -text]] 1
ok "replace: open-docs flagged a buffer modified" [bufget $pbuf modified] 1
# Current doc: replace one -> 1 in the focused buffer only (qbuf).
activate $qbuf
set ::search_scope "Current doc"
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 one
.results.rep.e delete 0 end ; .results.rep.e insert 0 1
search_replace_all
ok "replace: current-doc edited the buffer" [buf_text $qbuf]              "1 ZQ two\n"
ok "replace: current-doc count message" [.results.hdr.count cget -text]   "Replaced 1"
# Project: r.txt is CLOSED — replace red -> RED rewrites it on disk (confirm stubbed).
rename tk_messageBox _real_mb ; proc tk_messageBox {args} { return yes }
set ::search_scope "Project"
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 red
.results.rep.e delete 0 end ; .results.rep.e insert 0 RED
search_replace_all
rename tk_messageBox {} ; rename _real_mb tk_messageBox
set fh [open [file join $rdir r.txt] r] ; set rc [read $fh] ; close $fh
ok "replace: project rewrote the closed file on disk" [string trim $rc] "RED RED"
ok "replace: project count message" [string match "Replaced 2 *file*" [.results.hdr.count cget -text]] 1
# The find bar's Replace mode escalates carrying its replacement text.
find_open 1
.find.e delete 0 end ; .find.e insert 0 foo
.find.re delete 0 end ; .find.re insert 0 baz
search_from_bar
ok "replace: bar handoff opens the replace row" $::search_replace         1
ok "replace: bar handoff carries the replacement" [.results.rep.e get]    baz
find_close
search_show_replace 0
search_close
# Clean up the two edited buffers without a discard prompt.
foreach id [list $pbuf $qbuf] { if {[dict exists $::buffers $id]} { activate $id ; bufset $id modified 0 ; do_close } }
file delete -force $rdir

# --- find bar: whole-word toggle (D51) ---------------------------------------
# The bar's Whole word checkbox flows through buffer.matches: "one" appears three
# times in the buffer (standalone, inside "someone", inside "one_two"), but only
# the standalone one is a whole word.
set wf [tmpbytes "one someone one_two\n"]
do_open $wf
find_open 0
.find.e delete 0 end ; .find.e insert 0 one
set ::find_case 1 ; set ::find_word 0 ; find_update
ok "find: substring counts embedded"  [.find.count cget -text]         "3 matches"
set ::find_word 1 ; find_update
ok "find: whole-word counts standalone" [.find.count cget -text]       "1 match"
ok "find: whole-word starts list"     [llength $::find_starts]         1
set ::find_word 0 ; find_close
do_close

# --- Regex (D52 Phase C) -----------------------------------------------------
# The find bar and the Search panel gain a Regex toggle: the needle becomes a
# Tcl-ARE pattern (line-oriented), regsub backreferences drive replace, and Regex
# greys the Whole-word box (a pattern writes its own boundaries).
set xf [tmpbytes "id=7 name=al\nid=42 name=bo\n"]
do_open $xf
find_open 1
.find.e delete 0 end ; .find.e insert 0 {[0-9]+}
set ::find_case 1 ; set ::find_word 0 ; set ::find_regex 1 ; find_regex_changed
ok "find: regex counts variable-length hits" [.find.count cget -text]     "2 matches"
ok "find: regex greys the whole-word box" [.find.word cget -state]        disabled
# Replace with a backreference: id=N -> [N].
.find.e delete 0 end ; .find.e insert 0 {id=([0-9]+)}
.find.re delete 0 end ; .find.re insert 0 {[\1]}
find_replace_all
ok "find: regex replace-all applied backrefs" [buf_text $::cur] "\[7\] name=al\n\[42\] name=bo\n"
set ::find_regex 0 ; find_regex_changed
ok "find: clearing regex restores whole-word" [.find.word cget -state]    normal
find_close
bufset $::cur modified 0 ; do_close

# The panel's Regex toggle over a project (Current doc scope keeps it deterministic).
set xdir [file join [file dirname $tpath] riogui-rx-[clock clicks]]
file mkdir $xdir
set ff [open [file join $xdir n.txt] w] ; puts -nonewline $ff "aa11 bb22 cc33\n" ; close $ff
open_folder $xdir
do_open [file join $xdir n.txt] ; set nbuf $::cur
search_open
set ::search_scope "Current doc" ; set ::search_case 1 ; set ::search_word 0 ; set ::search_regex 1
search_regex_changed
.results.hdr.e delete 0 end ; .results.hdr.e insert 0 {[a-z]+[0-9]+}
search_run
ok "panel: regex counts three hits"   [.results.hdr.count cget -text]     "3 matches · 1 buffer"
ok "panel: regex greys whole-word"    [.results.hdr.word cget -state]     disabled
# The variable-length hits highlight to their own lengths (not a fixed needle len):
# "aa11" is 4 chars at line-col 1, so widget cols 9..13 after the 9-char row prefix.
ok "panel: regex hit sized to its match" [lrange [.results.well.body tag ranges fimatch] 0 1] {2.9 2.13}
# Regex replace with a backref through the buffer.
search_show_replace 1
.results.rep.e delete 0 end ; .results.rep.e insert 0 {\0!}
search_replace_all
ok "panel: regex replace applied" [buf_text $nbuf] "aa11! bb22! cc33!\n"
set ::search_regex 0 ; search_show_replace 0 ; search_close
bufset $nbuf modified 0 ; activate $nbuf ; do_close
file delete -force $xdir

# --- agent chat over the channel (D26/D30) -----------------------------------
# The agent now lives in the core and is driven over the channel: an agent turn is
# ordinary broadcast traffic (agent.* events) routed to the chat view, and the
# provider/key/policy are ops. The smoke's core runs in THIS process behind the
# socket, so the view crosses the real channel while we still inspect core state
# (rio::agent::provider_name, rio::claude::api::configured) directly.
# The editor center (.groups / the .cmp compare view) packs straight into the toplevel.
proc center_shows {w} { expr {[lsearch -exact [pack slaves .] $w] >= 0} }
# chat is the right site's tenant now (D35 c1b): shown = its body packed there. (The
# first-run default hides it — asserted on layout::default below; the dock-side ops
# above left the right site visible here, so it's on screen for the toggle checks.)
proc chat_shown {} { expr {[lsearch -exact [pack slaves .siteright.body] .chat] >= 0} }
ok "chat: shown while site visible"  [chat_shown]  1
set ::chat_shown 0 ; apply_chat_visibility
ok "chat: toggles off"               [chat_shown]  0
set ::chat_shown 1 ; apply_chat_visibility
ok "chat: toggles back on"           [chat_shown]  1
ok "chat: sash on the right"         [dict get [pack info .csash] -side] right

# View logic (deterministic): a streamed agent.* event applied straight to the view
# renders the same whether it arrived in-process or over the channel.
chat_clear
chat_event {event agent.delta   params {turn 1 text "hel"}}
chat_event {event agent.delta   params {turn 1 text "lo"}}
chat_event {event agent.message params {turn 1 role assistant text hello}}
ok "chat: deltas render as one Agent block" \
	[string match "*Agent*hello*" [.chat.log get 1.0 end]] 1
ok "chat: turn closed after message"  $::chat_turn_open 0

# A classified error renders its own block.
chat_clear
chat_event {event agent.error params {turn 2 code provider_down message boom}}
ok "chat: error block rendered" \
	[string match "*Error*boom*provider_down*" [.chat.log get 1.0 end]] 1

# Read-only tool activity (D26 slice 4): the call and its result render as muted
# transparency lines between the assistant's text, not as a prompt.
chat_clear
chat_event {event agent.delta       params {turn 3 text "let me look"}}
chat_event {event agent.tool        params {turn 3 id t1 name fs_list args path=src}}
chat_event {event agent.tool_result params {turn 3 id t1 name fs_list ok 1 summary {12 entries in src}}}
chat_event {event agent.message     params {turn 3 role assistant text {there are 12}}}
set tlog [.chat.log get 1.0 end]
ok "chat: tool call rendered"   [string match "*fs_list path=src*" $tlog] 1
ok "chat: tool result rendered" [string match "*12 entries in src*"  $tlog] 1
chat_clear
chat_event {event agent.tool_result params {turn 4 id t2 name fs_read ok 0 summary {refused: outside project}}}
ok "chat: a failed tool result uses the error tag" \
	[expr {[llength [.chat.log tag ranges tool-error]] > 0}] 1

# Proposed edit (D26 slice 5): the diff renders and the Approve/Reject bar appears;
# the result (or a decision) hides it again.
proc bar_shown {} { expr {[lsearch -exact [pack slaves .chat] .chat.approve] >= 0} }
chat_clear
set ::agent_auto_accept 0
chat_event {event agent.propose params {turn 7 id w1 name propose_edit path foo.txt diff "- old line
+ new line"}}
set plog [.chat.log get 1.0 end]
ok "chat: propose header rendered" [string match "*propose_edit*foo.txt*" $plog] 1
ok "chat: diff add line tagged"    [expr {[llength [.chat.log tag ranges diff-add]] > 0}] 1
ok "chat: diff del line tagged"    [expr {[llength [.chat.log tag ranges diff-del]] > 0}] 1
ok "chat: approval bar shown"      [bar_shown] 1
ok "chat: pending turn recorded"   $::pending_turn 7
chat_event {event agent.tool_result params {turn 7 id w1 name propose_edit ok 1 summary {edited foo.txt}}}
ok "chat: result hides approval bar" [bar_shown] 0
# Auto-accept: a proposal renders its diff but raises no bar (core applies it).
chat_clear ; set ::agent_auto_accept 1
chat_event {event agent.propose params {turn 8 id w2 name propose_create path bar.txt diff "+ x"}}
ok "chat: auto-accept raises no bar" [bar_shown] 0
set ::agent_auto_accept 0

# End to end over the channel: send a turn with the echo provider and pump the event
# loop until the streamed reply lands. agent.send returns only an ack — the content
# arrives as agent.* events the core broadcasts back over the socket (D30).
proc chat_run {text} {
	chat_clear
	.chat.input delete 1.0 end ; .chat.input insert end $text
	chat_send
	set deadline [expr {[clock milliseconds] + 3000}]
	while {[clock milliseconds] < $deadline} {
		update
		set msgs [dict get [rio_call agent.history {}] result messages]
		if {!$::chat_turn_open && [llength $msgs] >= 2} break
	}
}
chat_run "hello there"
set chatlog [.chat.log get 1.0 end]
ok "chat: transcript shows the prompt" [string match "*You*hello there*" $chatlog] 1
ok "chat: transcript shows the reply"  [string match "*Agent*echo: hello there*" $chatlog] 1
set msgs [dict get [rio_call agent.history {}] result messages]
ok "chat: core recorded the turn"      [llength $msgs] 2
ok "chat: assistant text is the reply" [dict get [lindex $msgs 1] text] "echo: hello there"

# Clear resets both the view and the core conversation.
chat_clear
ok "chat: clear empties transcript"  [string trim [.chat.log get 1.0 end]] ""
ok "chat: clear resets core" \
	[llength [dict get [rio_call agent.history {}] result messages]] 0

# The csash clamps the right site's width rather than letting it collapse.
.siteright configure -width 50 ; csash_drag
ok "chat: sash clamps min width"     [expr {[.siteright cget -width] >= 200}] 1

# --- agent provider selection + the Claude API key store, over the channel ----
# Point the core's secret store at a THROWAWAY dir so the smoke never touches the
# user's real ~/.local/share/rio/secrets (the core is in this process, so this
# override reaches it).
set ::secdir [file join [file dirname $tpath] riogui-sec-[clock clicks]]
set rio::secret::override_dir $::secdir
proc pump_until {cond {ms 3000}} {
	set deadline [expr {[clock milliseconds] + $ms}]
	while {[clock milliseconds] < $deadline} { update ; if {[uplevel 1 $cond]} return }
}

ok "provider: default is echo"        $::agent_provider echo
apply_provider
ok "provider: echo selected in core"  [rio::agent::provider_name] echo
ok "status: names echo agent"         [.chat.status cget -text] "Echo   ·   review edits"
set ::agent_provider claude ; apply_provider
ok "provider: claude selected in core" [rio::agent::provider_name] claude
ok "status: names claude agent"       [.chat.status cget -text] "Claude   ·   review edits"
set ::agent_auto_accept 1 ; chat_status_update
ok "status: shows auto-accept mode"   [.chat.status cget -text] "Claude   ·   auto-accept edits"
set ::agent_auto_accept 0 ; chat_status_update

# adopt_agent_status MIRRORS the core's live settings into the menus without
# writing back — attaching to an already-configured core must not reset it (D30).
# The core here has provider=claude (set just above); turn its auto-accept on, then
# stale the menu vars and confirm adopt pulls the core's truth without a write.
rio_result agent.autoaccept.set {on 1}
set ::agent_provider echo ; set ::agent_auto_accept 0
adopt_agent_status
ok "adopt: mirrors core provider"     $::agent_provider claude
ok "adopt: mirrors core auto-accept"  $::agent_auto_accept 1
ok "adopt: left the core provider be" [rio::agent::provider_name] claude
rio_result agent.autoaccept.set {on 0} ; adopt_agent_status   ;# back to gated for the key tests below

# Claude selected with no key stored: a turn must surface the face's actionable
# not_configured error (D26) — it never reaches the network.
ok "provider: no key stored yet"      [rio::claude::api::configured] 0
chat_clear
.chat.input delete 1.0 end ; .chat.input insert end "hi"
chat_send
pump_until {string match {*not_configured*} [.chat.log get 1.0 end]}
ok "provider: claude w/o key errors actionably" \
	[string match {*Settings*Claude API key*(not_configured)*} [.chat.log get 1.0 end]] 1

# The key dialog stores / clears through the agent.key.* ops (the core's 0600 store).
claude_key_dialog
ok "keydlg: opens"                    [winfo exists .claudekey] 1
ok "keydlg: clear disabled w/o key"   [.claudekey.btns.clear cget -state] disabled
.claudekey.e insert end "sk-ant-smoke-123"
claude_key_save .claudekey
ok "keydlg: closed after save"        [winfo exists .claudekey] 0
ok "keydlg: key now stored"           [rio::claude::api::configured] 1
ok "keydlg: secret is 0600" \
	[format %04o [expr {[file attributes [file join $::secdir claude-api.secret] -permissions] & 0777}]] 0600

# Re-open: Clear is enabled now, and clearing removes the secret.
claude_key_dialog
ok "keydlg: clear enabled with key"   [.claudekey.btns.clear cget -state] normal
claude_key_clear .claudekey
ok "keydlg: key cleared"              [rio::claude::api::configured] 0

# Back to the offline echo provider for the rest of the run.
set ::agent_provider echo ; apply_provider
chat_clear
file delete -force $::secdir

# --- compare / diff view (D28) -----------------------------------------------
# compare_open renders the core diff.lines alignment into the two read-only panes,
# with filler rows keeping equal lines level, and swaps .cmp in for .ed.
proc cmp_rows {t} { return [lindex [split [$t index end-1c] .] 0] }

compare_open "a\nb\nc\nd" "a\nB\nc\nd\ne" "left" "right"
ok "compare: shown flag set"        $::compare_shown 1
ok "compare: center shows .cmp"     [list [center_shows .cmp] [center_shows .groups]] {1 0}
ok "compare: headers set"           [list [.cmp.l.hdr cget -text] [.cmp.r.hdr cget -text]] {left right}
# Equal-length panes (fillers) so the lines stay aligned and scroll in lockstep.
ok "compare: panes equal length"    [expr {[cmp_rows .cmp.l.t] == [cmp_rows .cmp.r.t]}] 1
ok "compare: removed line tagged"   [expr {[llength [.cmp.l.t tag ranges del]] > 0}] 1
ok "compare: added line tagged"     [expr {[llength [.cmp.r.t tag ranges add]] > 0}] 1
ok "compare: filler rows present"   [expr {[llength [.cmp.l.t tag ranges filler]] > 0 \
                                         && [llength [.cmp.r.t tag ranges filler]] > 0}] 1
# Color-independent gutter markers (-/+) so the diff reads regardless of how the
# Tk build renders tag backgrounds under wrap.
proc cmp_lines {t} { return [split [string trimright [$t get 1.0 end] "\n"] "\n"] }
ok "compare: removed line has - marker" [expr {[lsearch -glob [cmp_lines .cmp.l.t] {- *}] >= 0}] 1
ok "compare: added line has + marker"   [expr {[lsearch -glob [cmp_lines .cmp.r.t] {+ *}] >= 0}] 1
ok "compare: panes are read-only"   [list [.cmp.l.t cget -state] [.cmp.r.t cget -state]] {disabled disabled}
ok "compare: close button present"  [winfo exists .cmp.bar.close] 1
# Line wrap (View ▸ Wrap Lines) reaches the compare panes — they have no h-scroll.
set ::wrap_lines 1 ; apply_wrap
ok "compare: wrap on reaches panes"  [list [.cmp.l.t cget -wrap] [.cmp.r.t cget -wrap]] {word word}
set ::wrap_lines 0 ; apply_wrap
ok "compare: wrap off reaches panes" [list [.cmp.l.t cget -wrap] [.cmp.r.t cget -wrap]] {none none}
# Opening a compare picks up the current wrap setting.
set ::wrap_lines 1
compare_open "x" "y" "l" "r"
ok "compare: open honors wrap"       [.cmp.l.t cget -wrap] word
set ::wrap_lines 0 ; apply_wrap
# Synced scrolling keeps both panes at the same fraction.
set ::cmp_syncing 0
cmp_yview moveto 0.5
ok "compare: scroll synced"         [expr {abs([lindex [.cmp.l.t yview] 0] - [lindex [.cmp.r.t yview] 0]) < 0.001}] 1
# The View menu exposes the entry points.
ok "compare: View menu has open"    [expr {![catch {.m.view index "Compare With File…"}]}] 1
ok "compare: View menu has close"   [expr {![catch {.m.view index "Close Compare"}]}] 1
compare_close
ok "compare: close restores editor" [list [center_shows .groups] [center_shows .cmp]] {1 0}
ok "compare: close clears flag"     $::compare_shown 0
# Agent-proposal routing: a *complex* proposed edit opens the compare view instead
# of dumping the whole diff inline; a small one stays inline; the Settings toggle
# disables the auto-open. Drive the decision with a stubbed compare_proposal so the
# view logic is tested without a live core proposal (core tests cover the pull).
ok "compare: button on approve bar" [winfo exists .chat.approve.cmp] 1
rename compare_proposal _real_compare_proposal
proc compare_proposal {turn} { lappend ::cmp_calls $turn ; return 1 }
proc big_diff {n} { set d {} ; for {set i 0} {$i < $n} {incr i} { lappend d "+ line $i" } ; return [join $d "\n"] }

set ::cmp_calls {} ; chat_clear ; set ::agent_auto_accept 0 ; set ::agent_compare_complex 1
chat_event [list event agent.propose params [list turn 11 id w9 name propose_edit path big.txt diff [big_diff 20]]]
ok "compare: complex edit auto-opens"   $::cmp_calls 11
ok "compare: inline diff skipped"       [string match "*opened in compare view*" [.chat.log get 1.0 end]] 1
ok "compare: approval bar still raised"  [bar_shown] 1

set ::cmp_calls {} ; chat_clear
chat_event {event agent.propose params {turn 12 id wA name propose_edit path small.txt diff "- a
+ b"}}
ok "compare: small edit stays inline"   $::cmp_calls {}
ok "compare: small edit diff inline"    [expr {[llength [.chat.log tag ranges diff-add]] > 0}] 1

set ::cmp_calls {} ; chat_clear ; set ::agent_compare_complex 0
chat_event [list event agent.propose params [list turn 13 id wB name propose_edit path big.txt diff [big_diff 20]]]
ok "compare: toggle off suppresses auto" $::cmp_calls {}
ok "compare: toggle off renders inline"  [expr {[llength [.chat.log tag ranges diff-add]] > 0}] 1
set ::agent_compare_complex 1
rename compare_proposal {} ; rename _real_compare_proposal compare_proposal
chat_clear ; approve_bar 0

# --- theme applier -----------------------------------------------------------
# The default theme (from the core's theme.get) drives the live widgets; named
# fonts exist, and switching re-applies colours live.
ok "theme: editor uses named font"   [::rio_real_t cget -font]             RioEditorFont
ok "theme: RioEditorFont created"    [expr {"RioEditorFont" in [font names]}] 1
ok "theme: default editor bg"        [::rio_real_t cget -background]        white
ok "theme: default status bg"        [.status cget -background]             "#dddddd"
ok "theme: chat log uses chat font"  [.chat.log cget -font]                RioChatFont
ok "theme: default chat bg"          [.chat.log cget -background]           white

do_theme solarized-dark
ok "theme: dark editor bg applied"   [::rio_real_t cget -background]        "#002b36"
ok "theme: dark cursor applied"      [::rio_real_t cget -insertbackground]  "#93a1a1"
ok "theme: dark status bg applied"   [.status cget -background]             "#073642"
ok "theme: dark tab bar applied"     [[gget $::focus tabs] cget -background] "#00212b"
ok "theme: dark chat bg applied"     [.chat.log cget -background]           "#002b36"

do_theme acme
ok "theme: acme body yellow applied" [::rio_real_t cget -background]        "#ffffea"
ok "theme: acme tag-blue chrome"     [.status cget -background]             "#eaffff"
ok "theme: acme selection applied"   [::rio_real_t cget -selectbackground]  "#eeee9e"

do_theme default
ok "theme: switched back to default" [::rio_real_t cget -background]        white
ok "theme: chat bg restored"         [.chat.log cget -background]           white

# --- wrap indent: align wrapped continuation lines under their own indent ------
ok "wrapind cols: spaces"  [wrapind_cols "    x"]  4
ok "wrapind cols: tab"     [wrapind_cols "\tx"]    8
ok "wrapind cols: tab+sp"  [wrapind_cols "\t  x"]  10
ok "wrapind cols: none"    [wrapind_cols "x"]      0

.ed.t delete 1.0 end
.ed.t insert 1.0 "\tindented line\nplain line\n    spaced line"
set cw [font measure RioEditorFont "0"]
set ::wrap_indent 1
apply_wrap_indent
ok "wrapind: indented line tagged" [expr {"wrapind:8" in [::rio_real_t tag names 1.0]}] 1
ok "wrapind: margin sized to font" [lindex [::rio_real_t tag configure wrapind:8 -lmargin2] 4] [expr {8*$cw}]
ok "wrapind: plain line untagged"  [expr {[lsearch -glob [::rio_real_t tag names 2.0] wrapind:*] < 0}] 1
ok "wrapind: spaced line tagged"   [expr {"wrapind:4" in [::rio_real_t tag names 3.0]}] 1
# an edit that changes a line's indent re-sizes just that line's tag (incremental)
.ed.t insert 2.0 "\t\t"
ok "wrapind: edit re-tags a line"  [expr {"wrapind:16" in [::rio_real_t tag names 2.0]}] 1
# toggling it off strips the indent from every line
set ::wrap_indent 0
apply_wrap_indent
ok "wrapind: off clears line 1"    [expr {[lsearch -glob [::rio_real_t tag names 1.0] wrapind:*] < 0}] 1
ok "wrapind: off empties ranges"   [::rio_real_t tag ranges wrapind:8] ""
# the choice persists to prefs.json
set ::wrap_indent 1
apply_wrap_indent
set pf [open [prefs_path] r] ; set prefs [::read $pf] ; close $pf
ok "wrapind: persisted"            [dict get [json::json2dict $prefs] wrap_indent] 1
set ::wrap_indent 0
apply_wrap_indent

# --- D27 glyphs on the live toolbar widgets ----------------------------------
ok "glyph: find next ↓"   [.find.next cget -text] "↓"
ok "glyph: find prev ↑"   [.find.prev cget -text] "↑"
ok "glyph: chat send ▶"   [.chat.send cget -text] "▶"

# --- D35 step (a): the tool-panel registry -----------------------------------
# The four tool panes are declared as data and queryable without a mapped window.
ok "panel: four registered"      [rio::panel::ids] {files git chat search}
ok "panel: files site"           [rio::panel::field files site]    left
ok "panel: git site"             [rio::panel::field git site]      left
ok "panel: chat site"            [rio::panel::field chat site]     right
ok "panel: search site bottom"   [rio::panel::field search site]   bottom
ok "panel: files body widget"    [rio::panel::field files body]    .pfiles
ok "panel: git refresh hook"     [rio::panel::field git refresh]   refresh_git
ok "panel: search refresh hook"  [rio::panel::field search refresh] search_run
ok "panel: chat refresh is none" [rio::panel::field chat refresh]  ""
ok "panel: title carried"        [rio::panel::field chat title]    Agent
ok "panel: exists known"         [rio::panel::exists git]          1
ok "panel: exists unknown"       [rio::panel::exists nope]         0
rio::panel::register files {site right}   ;# re-registering an existing id is ignored
ok "panel: register idempotent"  [rio::panel::field files site] left
# refresh dispatches through the declared hook: spy on git's hook, drive refresh_dock.
set ::_git_refreshed 0
rename refresh_git _real_refresh_git
proc refresh_git {} { set ::_git_refreshed 1 }
set ::dock_pane git
refresh_dock
ok "panel: refresh_dock -> hook" $::_git_refreshed 1
set ::_git_refreshed 0
set ::dock_pane files
rio::panel::refresh chat        ;# no hook — must be a harmless no-op
ok "panel: chat refresh no-op"  $::_git_refreshed 0
rename refresh_git {} ; rename _real_refresh_git refresh_git

# --- D35 step (b): the persisted layout object + apply_layout derivation --------
set _layout_save $::layout      ;# restore at the end so we don't disturb prior state

# The first-run default a brand-new user sees (no prefs): Files shown left, Git a
# background tab there, Agent hidden right, Search hidden bottom. Everything else persists.
set dfl [rio::layout::default]
ok "default: files site shown"     [dict get $dfl sites left visible] 1
ok "default: files is active"      [dict get $dfl sites left active] files
ok "default: agent hidden"         [dict get $dfl sites right visible] 0
ok "default: search hidden"        [dict get $dfl sites bottom visible] 0

# Migration from the pre-step-(b) flat keys preserves an UPGRADER's old experience
# (chat was shown by default before the layout object), distinct from the new first-run
# default above. Empty prefs -> the migrate default arrangement.
set m0 [rio::layout::normalize [rio::layout::migrate {}]]
ok "layout: default dock on left"  [expr {"files" in [dict get $m0 sites left panels]}] 1
ok "migrate: empty keeps chat shown" [dict get $m0 sites right visible] 1
ok "layout: search boots hidden"   [dict get $m0 sites bottom visible] 0
# dock_side=right + chat off: files/git unify into the right site (decision 1a),
# git is the active pane, and the right site is hidden (chat_shown=0).
set mr [rio::layout::normalize [rio::layout::migrate {dock_side right dock_pane git chat_shown 0}]]
ok "layout: migrate dock to right" [expr {"files" in [dict get $mr sites right panels] && "git" in [dict get $mr sites right panels]}] 1
ok "layout: migrate active git"    [dict get $mr sites right active] git
ok "layout: migrate right hidden"  [dict get $mr sites right visible] 0
ok "layout: migrate left emptied"  [dict get $mr sites left panels] {}

# normalize repairs a partial layout: a panel missing from every site returns to
# its registry-preferred site. It PRESERVES visibility now (the boot-only hide of
# the bottom strip moved to `boot`, so a runtime move to the bottom shows).
set bad {sites {left {panels files active files visible 1 size 220} right {panels {} active {} visible 1 size 340} bottom {panels {} active {} visible 1 size 160}}}
set fixed [rio::layout::normalize $bad]
ok "layout: repair restores git"   [expr {"git" in [dict get $fixed sites left panels]}] 1
ok "layout: repair restores chat"  [expr {"chat" in [dict get $fixed sites right panels]}] 1
ok "layout: repair restores search" [expr {"search" in [dict get $fixed sites bottom panels]}] 1
ok "layout: normalize keeps visible" [dict get $fixed sites bottom visible] 1
ok "layout: boot hides search-only bottom" [dict get [rio::layout::boot $bad] sites bottom visible] 0
# But once another panel is docked at the bottom, boot must NOT hide it (else that
# panel is stranded with no way back — the git-dragged-to-bottom regression).
set withgit {sites {left {panels files active files visible 1 size 220} right {panels chat active chat visible 1 size 340} bottom {panels {search git} active git visible 1 size 160}}}
ok "layout: boot keeps mixed bottom"  [dict get [rio::layout::boot $withgit] sites bottom visible] 1

# JSON round-trip: encode ::layout, parse it back, and the arrangement survives.
set dec [rio::layout::normalize [json::json2dict [rio::layout::json]]]
ok "layout: json roundtrip side"   [dict get $dec sites left panels] [dict get $::layout sites left panels]
ok "layout: json roundtrip active" [dict get $dec sites left active] [dict get $::layout sites left active]

# apply_layout derives real placement from the state. A panel body is packed into
# its site's .body area (D35 c1b); search->bottom, chat->right.
proc _packed {w site} { expr {[lsearch -exact [pack slaves .site$site.body] $w] >= 0} }
search_close
ok "search: closed to start"       $::search_shown 0
search_open "zztok"
ok "search: open sets flag"        $::search_shown 1
ok "search: bottom visible state"  [rio::layout::get bottom visible] 1
ok "search: results strip packed"  [_packed .results bottom] 1
search_close
ok "search: close clears flag"     $::search_shown 0
ok "search: results strip gone"    [_packed .results bottom] 0

# Chat visibility flows through the right site.
set ::chat_shown 0 ; apply_chat_visibility
ok "chat: hide -> site hidden"     [rio::layout::get right visible] 0
ok "chat: hide -> unpacked"        [_packed .chat right] 0
set ::chat_shown 1 ; apply_chat_visibility
ok "chat: show -> site visible"    [rio::layout::get right visible] 1
ok "chat: show -> packed"          [_packed .chat right] 1

# panel_toggle is the View-menu show/hide path. A solo pane (chat in right) hides its
# whole site and reveals it again; the ::shown_* mirror the checkmarks read follows.
panel_toggle chat
ok "toggle: chat hides"             [list [rio::layout::shown chat] $::shown_chat] {0 0}
panel_toggle chat
ok "toggle: chat shows again"       [list [rio::layout::shown chat] $::shown_chat] {1 1}
# A SHARED site (files+git on the left): toggling the shown pane yields to its sibling
# so the dock stays open on the other pane — it never hides a sibling unexpectedly.
panel_reveal files
panel_toggle files
ok "toggle: shared yields to sibling" [list [rio::layout::get left visible] [rio::layout::get left active]] {1 git}
ok "toggle: sibling now shown"        [list $::shown_files $::shown_git] {0 1}
panel_reveal files

# Sizes are state-driven and persisted (were ephemeral before step b).
rio::layout::put left size 250 ; apply_layout
ok "size: dock width derived"      [.siteleft cget -width] 250
prefs_save
set pf [open [prefs_path] r] ; set pj [json::json2dict [::read $pf]] ; close $pf
ok "prefs: layout object written"  [dict exists $pj layout] 1
ok "prefs: flat keys clean-cut"    [expr {[dict exists $pj dock_side] || [dict exists $pj chat_shown]}] 0
ok "prefs: size persisted"         [dict get $pj layout sites left size] 250

set ::layout $_layout_save ; apply_layout    ;# restore the pre-block arrangement

# --- D35 c1b: host tab strips per site + heterogeneous panels in one strip -----
set _layout_c1b $::layout
apply_layout
# Uniform decision: every visible site shows a tab strip, single-panel ones too.
ok "c1b: left strip has both tabs"  [expr {[winfo exists .siteleft.tabs.files] && [winfo exists .siteleft.tabs.git]}] 1
ok "c1b: right site has a chat tab" [winfo exists .siteright.tabs.chat] 1
ok "c1b: chat tab titled Agent"     [.siteright.tabs.chat cget -text] Agent
search_open "zz"
ok "c1b: bottom site has search tab" [.sitebottom.tabs.search cget -text] Search
search_close
# Heterogeneous panels in one site render as ONE tab strip (the c1 acceptance):
# dock git into the bottom site beside search; the left site drops to one tab.
dict set ::layout sites bottom panels {search git}
dict set ::layout sites left   panels {files}
set ::layout [rio::layout::normalize $::layout]
rio::layout::put bottom visible 1
apply_layout
ok "c1b: bottom strip lists both"   [lsort [tabs_of bottom]] {git search}
ok "c1b: left strip single tab"     [tabs_of left] files
# Only the active tab's body shows; activating the git tab brings its body up.
ok "c1b: search body active first"  [list [site_shows bottom .results] [site_shows bottom .pgit]] {1 0}
site_tab_click bottom git
ok "c1b: git body after tab click"  [list [site_shows bottom .pgit] [site_shows bottom .results]] {1 0}
set ::layout $_layout_c1b ; apply_layout

# --- D35 c2: relocate a panel to another site (the "Move to" gesture) ----------
set _layout_c2 $::layout
# Move the git panel down to the bottom site: it leaves the left, lands in the
# bottom as its active tab, and the bottom becomes visible (a move shows the site).
panel_move git bottom
ok "c2: git left the left site"     [expr {"git" ni [rio::layout::get left panels]}] 1
ok "c2: git in the bottom site"     [expr {"git" in [rio::layout::get bottom panels]}] 1
ok "c2: bottom now visible"         [rio::layout::get bottom visible] 1
ok "c2: git is the active tab"      [rio::layout::get bottom active] git
ok "c2: git body shown at bottom"   [site_shows bottom .pgit] 1
ok "c2: files still on the left"    [rio::layout::get left panels] files
# Bring the Agent onto the LEFT with files — the symmetry the dock-side toggle
# couldn't reach (chat had no mover before c2).
panel_move chat left
ok "c2: chat joined the left site"  [expr {"chat" in [rio::layout::get left panels]}] 1
ok "c2: left strip has a chat tab"  [winfo exists .siteleft.tabs.chat] 1
ok "c2: chat mirror follows site"   $::chat_shown 1
# A no-op move (already there, or an unknown target) leaves the layout untouched.
set snap $::layout
panel_move chat left ; panel_move chat nowhere
ok "c2: no-op move is inert"        $::layout $snap
set ::layout $_layout_c2 ; apply_layout

# --- D35 c3: relocate a panel by DRAGGING its tab ------------------------------
set _layout_c3 $::layout
# A press + release that never crosses the drag threshold is a click — it activates.
show_pane files
tab_press left git 50 50
tab_release left git 51 51
ok "c3: sub-threshold is a click"  $::dock_pane git
show_pane files
# A motion past the threshold arms a real drag.
tab_press left git 0 0
tab_motion 100 100
ok "c3: motion arms the drag"      [dict get $::tabdrag active] 1
# Release over a valid target site relocates (headless can't winfo-contain, so stub
# the hit-test to name the drop site — same seam the pointer would resolve live).
rename site_under_pointer _real_sup
proc site_under_pointer {X Y} { return bottom }
tab_release left git 100 100
ok "c3: drag relocated to bottom"  [expr {"git" in [rio::layout::get bottom panels]}] 1
ok "c3: drag cleared its state"    [info exists ::tabdrag] 0
# A drop onto the source site (or nowhere) is a no-op.
proc site_under_pointer {X Y} { return left }
set snap $::layout
tab_press left files 0 0 ; tab_motion 100 100 ; tab_release left files 100 100
ok "c3: self-drop is a no-op"      $::layout $snap
rename site_under_pointer {} ; rename _real_sup site_under_pointer
set ::layout $_layout_c3 ; apply_layout

# Recovery: a panel dragged into a site that then gets hidden must be reachable
# from the View menu. panel_reveal shows its site and makes it the active tab —
# no pane can become unreachable (the git-vanished-on-startup fix).
set _layout_rec $::layout
panel_move git bottom
rio::layout::put bottom visible 0 ; apply_layout    ;# git now stranded in a hidden site
ok "reveal: git starts hidden"     [rio::layout::get bottom visible] 0
panel_reveal git
ok "reveal: brings the site back"  [rio::layout::get bottom visible] 1
ok "reveal: makes git active"      [rio::layout::get bottom active] git
ok "reveal: git body is shown"     [site_shows bottom .pgit] 1
set ::layout $_layout_rec ; apply_layout

# --- D35: dock sizes are user-chosen and stable (not content-driven) -----------
# A dock's size stays what the user chose; switching between its tabs (a tall git
# diff vs the short Search strip) must not resize it. Side sites are fixed-width,
# the bottom fixed-height (propagate off); only a sash drag changes a dock's size.
set _layout_sz $::layout
dict set ::layout sites bottom panels {search git}
dict set ::layout sites left   panels {files}
set ::layout [rio::layout::normalize $::layout]
rio::layout::put bottom visible 1
rio::layout::put bottom size 200
apply_layout
ok "size: bottom propagate off"        [pack propagate .sitebottom] 0
ok "size: bottom height from layout"   [.sitebottom cget -height] 200
site_tab_click bottom git    ; set hg [.sitebottom cget -height]
site_tab_click bottom search ; set hs [.sitebottom cget -height]
ok "size: bottom height stable on switch" [list $hg $hs] {200 200}
# The bsash drag records the new height into the layout on release.
.sitebottom configure -height 999 ; bsash_drag          ;# pointer off-sash -> clamps
ok "size: bsash clamps and drives height" [expr {[.sitebottom cget -height] >= 60}] 1
set ::layout $_layout_sz ; apply_layout

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

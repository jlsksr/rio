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
	set b .dock.files.well.body
	set out {}
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set L [expr {$i + 1}]
		lappend out [string range [$b get "$L.0" "$L.0 lineend"] 4 end]
	}
	return $out
}
proc nav_click {row} {
	rl_select .dock.files.well.body $row ; rl_activate .dock.files.well.body
}

set tf [file tempfile tpath] ; close $tf
set proj [file join [file dirname $tpath] riogui-nav-[clock clicks]]
file mkdir [file join $proj sub]
set zf [open [file join $proj zeta.txt] w] ; puts -nonewline $zf "ZETA\n" ; close $zf

ok "pane: empty before folder open" [nav_labels] {{Open a folder…}}
open_folder $proj
ok "pane: nav_dir is the root"   $::nav_dir              [file normalize $proj]
ok "pane: header is project name" [.dock.files.hdr.head cget -text] [file tail $proj]
ok "pane: dirs then files"        [nav_labels]           {sub/ zeta.txt}
# Bands: a selection covers exactly its row (through the newline, so it spans full
# width); a hover tags the hovered row. (D42 rich-list.)
rl_select .dock.files.well.body 0
ok "pane: selection band on row 0" [.dock.files.well.body tag ranges selrow]   {1.0 2.0}
rl_set_hover .dock.files.well.body 1
ok "pane: hover band on row 1"     [.dock.files.well.body tag ranges hoverrow] {2.0 3.0}
update idletasks
ok "pane: scrollbar hidden when list fits" \
	[expr {[lsearch -exact [pack slaves .dock.files.well] .dock.files.well.sb] < 0}] 1

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
ok "pane: refresh control wired"   [bind .dock.files.hdr.refresh <Button-1>] populate_nav
uplevel #0 [bind .dock.files.hdr.refresh <Button-1>]
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
file delete -force $proj

# --- dock layout: switch panes and switch sides ------------------------------
proc dock_slaves {} { pack slaves .dock }
proc dock_shows {w} { expr {[lsearch -exact [dock_slaves] $w] >= 0} }

show_pane git
ok "dock: git pane shown"         [list [dock_shows .dock.git] [dock_shows .dock.files]] {1 0}
ok "dock: dock_pane is git"       $::dock_pane           git
show_pane files
ok "dock: files pane shown"       [list [dock_shows .dock.files] [dock_shows .dock.git]] {1 0}

# The dock width must NOT change when switching panes (regression: the git pane's
# diff defaults to 80 cols / editor font and ballooned the whole window).
show_pane files ; update idletasks ; set wf [winfo reqwidth .dock]
show_pane git   ; update idletasks ; set wg [winfo reqwidth .dock]
ok "dock: width stable on switch"  [expr {abs($wg - $wf) < 8}] 1
show_pane files

ok "dock: default side is left"   [dict get [pack info .dock] -side] left
set ::dock_side right ; place_dock
ok "dock: moved to the right"     [dict get [pack info .dock] -side] right
ok "dock: editor still expands"   [dict get [pack info .groups] -expand] 1
set ::dock_side left ; place_dock
ok "dock: back to the left"       [dict get [pack info .dock] -side] left

# The sash sits between the dock and the editor (same edge as the dock), and a
# drag clamps the dock width rather than letting it collapse or eat the editor.
ok "sash: parked on the dock edge" [dict get [pack info .sash] -side] left
.dock configure -width 40 ; sash_drag      ;# pointer not over sash -> clamps to min
ok "sash: clamps to minimum width" [expr {[.dock cget -width] >= 120}] 1

# --- editor scrollbars + line wrapping ---------------------------------------
# The vertical bar is wired straight to the text; the horizontal bar auto-hides
# (gridscroll) when no line overflows, and wrapping drops it (no h-scroll wrapped).
# The auto-hide logic is driven directly with fractions: in a withdrawn window the
# text never reports real overflow, so we can't lean on live geometry here.
proc hsb_shown {} { expr {[lsearch -exact [grid slaves .eg0] .eg0.hsb] >= 0} }
ok "editor: vsb wired to text"   [::rio_real_t cget -yscrollcommand] {.eg0.vsb set}
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
		set b .dock.files.well.body
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
		set b .dock.git.well.body ; set L [expr {$row + 1}]
		return [$b get "$L.0" "$L.0 lineend"]
	}
	show_pane git              ;# the file pane was active above; git refreshes on show
	proc git_shows_diff {} { expr {[lsearch -exact [pack slaves .dock.git] .dock.git.diff] >= 0} }
	ok "git: branch shown"        [.dock.git.hdr.branch cget -text] "⎇ main"
	ok "git: change listed"       [string match "* M a.txt" [git_line 0]] 1
	ok "git: diff hidden until pick" [git_shows_diff] 0
	rl_select .dock.git.well.body 0
	ok "git: diff shows on pick"   [git_shows_diff] 1
	ok "git: diff shows the edit"  [string match "*+two*" [.dock.git.diff get 1.0 end-1c]] 1

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
	menu .tm -tearoff 0
	nav_menu_build .tm [list file [file join $gdir a.txt]]
	ok "menu: modified file offers Stage" [menu_labels .tm] {Open {Copy Path} --- Stage}
	.tm delete 0 end ; nav_menu_build .tm [list file [file join $gdir u.txt]]
	ok "menu: untracked file offers Track" [menu_labels .tm] {Open {Copy Path} --- {Track (git add)}}
	.tm delete 0 end ; nav_menu_build .tm [list dir [file join $gdir sub]]
	ok "menu: dir with changes offers Stage folder" [menu_labels .tm] {Open --- {Stage folder}}
	.tm delete 0 end ; git_menu_build .tm [dict create x { } y M path a.txt]
	ok "menu: git unstaged offers Stage" [menu_labels .tm] {Open {Copy Path} --- Stage}
	.tm delete 0 end ; git_menu_build .tm [dict create x A y { } path c.txt]
	ok "menu: git staged offers Unstage" [menu_labels .tm] {Open {Copy Path} --- Unstage}
	destroy .tm

	# The action proc: stage/unstage a path through the core, then the pane repaints.
	# git_xy_for reads a path's two status chars back out of the git list.
	proc git_xy_for {name} {
		set b .dock.git.well.body
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
	proc git_bar_shown {} { expr {[lsearch -exact [pack slaves .dock.git] .dock.git.commit] >= 0} }
	ok "commit: bar shown when staged" [git_bar_shown] 1
	# The greyed "message" hint shows while the entry is empty and hides once text is typed.
	proc git_hint_shown {} { expr {[place info .dock.git.commit.msg.ph] ne ""} }
	.dock.git.commit.msg delete 0 end
	ok "commit: hint shown when empty" [git_hint_shown] 1
	.dock.git.commit.msg insert 0 "x"
	ok "commit: hint hidden when typed" [git_hint_shown] 0
	.dock.git.commit.msg delete 0 end
	ok "commit: hint back when cleared" [git_hint_shown] 1
	# An empty (whitespace) summary is refused without touching the repo: still staged.
	.dock.git.commit.msg delete 0 end ; .dock.git.commit.msg insert 0 "   " ; git_commit
	ok "commit: empty message no-ops"  [git_xy_for a.txt] "M "
	# A real summary commits the index: a.txt leaves the change list, the entry clears,
	# and with nothing staged left the bar auto-hides (b.txt/u.txt stay unstaged).
	.dock.git.commit.msg delete 0 end ; .dock.git.commit.msg insert 0 "smoke commit" ; git_commit
	ok "commit: staged change committed" [git_xy_for a.txt] ""
	ok "commit: entry cleared"           [.dock.git.commit.msg get] ""
	ok "commit: bar hidden after commit" [git_bar_shown] 0
	after cancel refresh_git   ;# drop the pending git_flash restore before teardown
	file delete -force $gdir
} else {
	puts "SKIP  git pane checks (git not installed)"
}

# --- agent chat over the channel (D26/D30) -----------------------------------
# The agent now lives in the core and is driven over the channel: an agent turn is
# ordinary broadcast traffic (agent.* events) routed to the chat view, and the
# provider/key/policy are ops. The smoke's core runs in THIS process behind the
# socket, so the view crosses the real channel while we still inspect core state
# (rio::agent::provider_name, rio::claude::api::configured) directly.
proc center_shows {w} { expr {[lsearch -exact [pack slaves .] $w] >= 0} }
ok "chat: shown by default"          [center_shows .chat]  1
set ::chat_shown 0 ; apply_chat_visibility
ok "chat: toggles off"               [center_shows .chat]  0
set ::chat_shown 1 ; apply_chat_visibility
ok "chat: toggles back on"           [center_shows .chat]  1
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

# The chat sash clamps the width rather than letting the column collapse.
.chat configure -width 50 ; csash_drag
ok "chat: sash clamps min width"     [expr {[.chat cget -width] >= 200}] 1

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

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

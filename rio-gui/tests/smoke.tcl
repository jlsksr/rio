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
# The buffer ids currently backed by tab widgets in the focused group's strip. Tab
# handles are named .eg<g>.tabs.b$id; the strip also holds the D57 scroll arrows
# (al/ar), so select only the b* handles.
proc tab_ids {} {
	set ids {}
	foreach w [winfo children [gget $::focus tabs]] {
		set nm [winfo name $w]
		if {[string index $nm 0] eq "b"} { lappend ids [string range $nm 1 end] }
	}
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

# --- the anonymous (no-project) workspace resumes over the wire (D72) ---------
# No folder has been opened yet, so this loose file belongs to the anonymous
# session. session_save + workspace.get must round-trip it across the real channel.
ok "anon ws: no project open"   [dict get [rio_call project.get {}] result root]  ""
session_save
set _aws [rio_call workspace.get {}]
ok "anon ws: save reported ok"  [dict get $_aws ok]                                true
ok "anon ws: loose file resumes" \
	[expr {[lsearch -exact [dict get $_aws result open] $p] >= 0}]                1

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

# --- undo coalescing through the proxy (D90) ---------------------------------
# Typing must not cost one undo step per keystroke: the core merges a run of
# one-character edits into one, sealed at each blank, so undo takes back a word
# at a time. The proxy also carries a one-shot break, which a mode dispatching a
# discrete command arms to keep each repetition separately undoable.
do_open [tmpbytes ""]
foreach ch [split "two words" ""] { .ed.t insert insert $ch }
ok "coalesce: typed text"        [rio::doc::text $::cur] "two words"
do_undo
ok "coalesce: one undo per word" [rio::doc::text $::cur] "two "
do_undo
ok "coalesce: the run undid whole" [rio::doc::text $::cur] ""
undo_break
ok "coalesce: break arms once"   [list [undo_coalesce] [undo_coalesce]] {0 1}
foreach ch {a b} { undo_break ; .ed.t insert insert $ch }
do_undo
ok "coalesce: a break splits the run" [rio::doc::text $::cur] "a"
do_save ; do_close

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

# --- open dialog: multi-select opens every chosen file (D77) ------------------
# tk_getOpenFile -multiple 1 returns a LIST of paths; open_dialog must open each,
# not just the first. Stub the native chooser (headless can't drive it) to hand
# back two files and confirm both land as buffers, the last one active.
set m1 [tmpbytes "MULTI ONE\n"]
set m2 [tmpbytes "MULTI TWO\n"]
rename ::tk_getOpenFile ::_saved_getOpenFile
proc ::tk_getOpenFile {args} { return [list $::_stub_open_a $::_stub_open_b] }
set ::_stub_open_a $m1 ; set ::_stub_open_b $m2
set _was_remote $::core_remote ; set ::core_remote 0   ;# force the native-chooser branch
set before [llength [gorder $::focus]]
open_dialog
set ::core_remote $_was_remote
rename ::tk_getOpenFile {}
rename ::_saved_getOpenFile ::tk_getOpenFile
ok "open: both files opened"    [llength [gorder $::focus]] [expr {$before + 2}]
ok "open: last one active"      [bufget $::cur path]        $m2
ok "open: first one present"    [expr {[lsearch -exact [lmap id [gorder $::focus] {bufget $id path}] $m1] >= 0}] 1

# --- OS file-drop handler opens what's dropped (D86) --------------------------
# Headless can't fire a real <<Drop>>, so drive the handler proc directly with a
# synthetic path list — the same way the internal-DnD tests drive their resolvers.
# tkdnd is an OPTIONAL dependency and its PRESENCE is a property of the host, not
# something to assert: a bare Linux CI box has none, while the Magicsplat
# distribution bundles it on Windows (CAVEATS.md), where the drop targets really do
# get registered. Either way, what we test below is the dispatch a real <<Drop>>
# would trigger.
ok "drop: tkdnd presence is a boolean" [expr {$::have_tkdnd in {0 1}}] 1
# Real path: a dropped file opens as a buffer.
set d1 [tmpbytes "DROPPED ONE\n"]
set dbefore [llength [gorder $::focus]]
dnd_open_files [list $d1]
ok "drop: dropped file opened"    [bufget $::cur path]        $d1
ok "drop: one new buffer"         [llength [gorder $::focus]] [expr {$dbefore + 1}]
# Dispatch: stub do_open/open_folder to record which branch a mixed drop (a directory +
# a file) takes, without perturbing project or buffer state.
set ddir [file dirname $d1]
set ::_drop_log {}
rename ::do_open ::_saved_do_open
rename ::open_folder ::_saved_open_folder
proc ::do_open {p}     { lappend ::_drop_log [list file $p] ; return 1 }
proc ::open_folder {p} { lappend ::_drop_log [list dir  $p] ; return 1 }
dnd_open_files [list $ddir $d1]
rename ::do_open {} ; rename ::_saved_do_open ::do_open
rename ::open_folder {} ; rename ::_saved_open_folder ::open_folder
ok "drop: folder routes to open_folder" [lindex $::_drop_log 0] [list dir  $ddir]
ok "drop: file routes to do_open"       [lindex $::_drop_log 1] [list file $d1]

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

# The core's RELEASE version (D123), also learned from the greeting. This is the guard
# that the two halves of a checkout agree: the core under test is a REALLY SPAWNED
# child process reporting its own rio::version over the wire, and the GUI holds it
# against the literal it sourced. One file defines it, so a second copy cannot appear
# without this failing.
ok "hello: core version recorded"    $::core_version $rio::version
ok "hello: …and About just states it" [about_version] $rio::version

# A core too old to report one must not be read as "the same version" — About says
# nothing extra rather than making a claim (the D19 fallback). A DIFFERENT version is
# the --connect case, and then the row names it, since that is what a bug report needs.
set _cv $::core_version
set ::core_version ""      ; ok "hello: no core version, no claim" [about_version] $rio::version
set ::core_version "9.9.9" ; ok "hello: a differing core is named" \
	[about_version] "$rio::version (core 9.9.9)"
set ::core_version $_cv

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

# Row payloads {type abspath}, in render order — used for the tree/indent assertions
# (indent shifts the label text, so payloads are the depth-independent thing to check).
proc nav_payloads {} {
	set b .pfiles.well.body
	set out {}
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} { lappend out [rl_payload $b $i] }
	return $out
}
set tf [file tempfile tpath] ; close $tf
set proj [file join [file dirname $tpath] riogui-nav-[clock clicks]]
file mkdir [file join $proj sub]
set inf [open [file join $proj sub inner.txt] w] ; puts -nonewline $inf "INNER\n" ; close $inf
set zf [open [file join $proj zeta.txt] w] ; puts -nonewline $zf "ZETA\n" ; close $zf

ok "pane: empty before folder open" [nav_labels] {{Open a folder…}}
open_folder $proj
ok "pane: nav_root is the root"  $::nav_root             [file normalize $proj]
ok "pane: header is project name" [.pfiles.hdr.head cget -text] [file tail $proj]
ok "pane: root collapsed shows dirs then files" [nav_labels] {sub/ zeta.txt}
# Bands: a selection covers exactly its row (through the newline, so it spans full
# width); a hover tags the hovered row. (D42 rich-list.)
rl_select .pfiles.well.body 0
ok "pane: selection band on row 0" [.pfiles.well.body tag ranges selrow]   {1.0 2.0}
rl_set_hover .pfiles.well.body 1
ok "pane: hover band on row 1"     [.pfiles.well.body tag ranges hoverrow] {2.0 3.0}
# The pane's bar auto-hides (autoscroll) when the rows fit. Drive that with fractions
# rather than off the live pane, the same way the editor's hsb check below does: a
# withdrawn window's text never reports real overflow, and how much geometry it reports
# at all differs by host. Read off the pane, this asserted nothing where it passed (the
# widget answered 0.0 1.0 whatever its height) and failed outright on a host whose
# withdrawn pane came back short enough to look overflowing.
proc nav_sb_shown {} { expr {[lsearch -exact [pack slaves .pfiles.well] .pfiles.well.sb] >= 0} }
autoscroll .pfiles.well.sb .pfiles.well.body 0.0 0.5
ok "pane: scrollbar shown when list overflows" [nav_sb_shown] 1
autoscroll .pfiles.well.sb .pfiles.well.body 0.0 1.0
ok "pane: scrollbar hidden when list fits"     [nav_sb_shown] 0

# Unfold the subdir (row 0 = sub/) in place: its child renders indented right below it,
# the twisty flips ▸→▾, and the subdir stays put (a tree, not a descend). Then fold it back.
set subp [file join $::nav_root sub]
nav_click 0
ok "pane: sub is now unfolded"    [dict exists $::nav_expanded $subp] 1
ok "pane: unfolded child in order" [nav_payloads] \
	[list [list dir $subp] [list file [file join $subp inner.txt]] [list file [file join $::nav_root zeta.txt]]]
# The sub/ row's glyph sits just past the 2-char gutter (index 2) and flips ▸→▾ on unfold.
ok "pane: twisty shows ▾ unfolded" [string index [.pfiles.well.body get 1.0 "1.0 lineend"] 2] "▾"
# The depth-1 child sits one indent step (two spaces) right of the gutter, so its glyph
# column (index 4) holds the file glyph while the dir's glyph sat at index 2.
ok "pane: child row is indented"   [string range [.pfiles.well.body get 2.0 "2.0 lineend"] 2 4] "  ▪"
nav_click 0
ok "pane: folded back to root"    [dict exists $::nav_expanded $subp] 0
ok "pane: folded shows just root" [nav_payloads] \
	[list [list dir $subp] [list file [file join $::nav_root zeta.txt]]]
# Click routing (D87): on a dir row the arrow is everything left of the name, which starts at
# column 2+2·depth+2 — a click there unfolds, a click on the name is left for double-click; a
# file row has no arrow. (nav_col_is_arrow is the pixel-free core of nav_b1's decision.)
ok "arrow: depth-0 dir glyph col is arrow" [nav_col_is_arrow dir 0 2] 1
ok "arrow: depth-0 dir name col not arrow" [nav_col_is_arrow dir 0 4] 0
ok "arrow: depth-1 dir arrow at col 5"     [nav_col_is_arrow dir 1 5] 1
ok "arrow: depth-1 dir name at col 6"      [nav_col_is_arrow dir 1 6] 0
ok "arrow: a file row is never an arrow"   [nav_col_is_arrow file 0 2] 0

# Selection is one row at a time: the Text widget's own text-selection gestures are
# neutralised so a drag or shift/multi-click can't sweep a stray multi-line highlight
# across the row model (-state disabled does not suppress it). The drag binding is the
# one a user trips accidentally; assert the whole set breaks, on the files pane and the
# git list (both rl_init bodies). rl_init sets these; the files pane's Button-1 override
# leaves them intact.
foreach seq {<B1-Motion> <Shift-Button-1> <Triple-Button-1> <Shift-Down>} {
	ok "select: files pane $seq breaks text-select" [bind .pfiles.well.body $seq] break
	ok "select: git list  $seq breaks text-select"  [bind .pgit.well.body   $seq] break
}

# fs.changed repaints the files pane when the write lands in the shown directory, so an
# agent-created file appears without a manual reload (D47). Create a file on disk behind
# the pane's back, then feed it the event the core would broadcast. The repaint is debounced
# (D94 — one op can announce many paths), so run the event loop long enough for its timer.
proc drain_fs {} {
	set ::_fsdrain 0 ; after [expr {$::fs_changed_delay * 3}] {set ::_fsdrain 1}
	vwait ::_fsdrain
}
set nf [open [file join $proj gamma.txt] w] ; puts -nonewline $nf "G\n" ; close $nf
ok "pane: new file absent pre-event"   [expr {[lsearch -exact [nav_labels] gamma.txt] >= 0}] 0
dispatch_event [dict create event fs.changed params [dict create path [file join $proj gamma.txt]]]
drain_fs
ok "pane: fs.changed reveals new file" [expr {[lsearch -exact [nav_labels] gamma.txt] >= 0}] 1
# A burst of events from ONE op costs ONE repaint, not one per path (D94): three paths in a
# row arm a single timer, and the pane is up to date once it has run.
set tf [open [file join $proj theta.txt] w] ; puts -nonewline $tf "T\n" ; close $tf
foreach f {theta.txt gamma.txt theta.txt} {
	dispatch_event [dict create event fs.changed params [dict create path [file join $proj $f]]]
}
ok "pane: a burst arms one repaint" [llength $::fs_changed_paths] 3
drain_fs
ok "pane: burst repaint drains"     [list $::fs_changed_paths $::fs_changed_after] {{} {}}
ok "pane: burst reveals the file"   [expr {[lsearch -exact [nav_labels] theta.txt] >= 0}] 1
file delete [file join $proj theta.txt] ; populate_nav
# A write under a FOLDED directory does not repaint the pane (nav_dir_visible is false for
# sub/, which we folded back above): create delta.txt in the root but signal a change under
# sub/ — the guard skips the repaint, so delta.txt must stay hidden until a real refresh.
set df [open [file join $proj delta.txt] w] ; puts -nonewline $df "D\n" ; close $df
dispatch_event [dict create event fs.changed params [dict create path [file join $proj sub deep.txt]]]
drain_fs
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

# --- file-management context actions (D48/D87) -------------------------------
# The verbs sit between Copy Path and any git items; with no repo here the row menu is
# just Open/Copy Path + the four fs verbs. Every real row (file OR dir) now offers all
# four — the tree has no ".." placeholder to exclude (D87) — and New File/Folder target
# the row's OWN directory: a file row → its parent, a dir row → inside that dir.
proc menu_labels2 {m} {
	set out {}
	for {set i 0} {$i <= [$m index end]} {incr i} {
		lappend out [expr {[$m type $i] eq "separator" ? "---" : [$m entrycget $i -label]}]
	}
	return $out
}

# Menubar helpers, used both by the openai-provider block and by the menu-shape checks
# far below — defined up here so the earlier of the two can reach them.
proc _menu_has_label {m label} {
	for {set i 0} {$i <= [$m index end]} {incr i} {
		if {![catch {$m entrycget $i -label} l] && $l eq $label} { return 1 }
	}
	return 0
}
proc ext_menu_labels {} {
	set out {}
	for {set i 0} {$i <= [.m.extensions index end]} {incr i} {
		if {[catch {.m.extensions entrycget $i -label} l]} continue
		lappend out $l
	}
	return $out
}
proc menubar_labels {} {
	set out {}
	for {set i 0} {$i <= [.m index end]} {incr i} {
		if {![catch {.m entrycget $i -label} l] && $l ne ""} { lappend out $l }
	}
	return $out
}

menu .fsm -tearoff 0
nav_menu_build .fsm [list file [file join $proj zeta.txt]]
ok "fs-menu: file row has all four verbs" [menu_labels2 .fsm] \
	[list Open {Copy Path} --- {New File…} {New Folder…} Rename… Delete…]
ok "fs-menu: New File targets file's parent" \
	[lindex [.fsm entrycget 3 -command] 1] [file join $proj]
.fsm delete 0 end ; nav_menu_build .fsm [list dir [file join $proj sub]]
ok "fs-menu: dir row also has all four" [menu_labels2 .fsm] \
	[list Open --- {New File…} {New Folder…} Rename… Delete…]
ok "fs-menu: New File targets the dir itself" \
	[lindex [.fsm entrycget 2 -command] 1] [file join $proj sub]
destroy .fsm

# fs_apply_create writes through the core (into the given dir) and the pane shows it.
fs_apply_create $proj file kappa.txt
ok "fs: created file on disk"   [file isfile [file join $proj kappa.txt]] 1
ok "fs: created file in pane"   [expr {[lsearch -exact [nav_labels] kappa.txt] >= 0}] 1
fs_apply_create $proj dir newdir
ok "fs: created folder on disk" [file isdirectory [file join $proj newdir]] 1
ok "fs: created folder in pane" [expr {[lsearch -exact [nav_labels] newdir/] >= 0}] 1
# Creating inside a subdir auto-unfolds it, so the new entry is on screen (D87).
fs_apply_create [file join $::nav_root sub] file within.txt
ok "fs: sub auto-unfolded on create" [dict exists $::nav_expanded [file join $::nav_root sub]] 1
ok "fs: new file under sub is shown"  [expr {[lsearch -exact [nav_payloads] [list file [file join $::nav_root sub within.txt]]] >= 0}] 1
dict unset ::nav_expanded [file join $::nav_root sub] ; populate_nav   ;# refold for the rows that follow
# An invalid (non-single-component) name is refused: nothing created, no crash.
fs_apply_create $proj file "a/b.txt"
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

# --- reopen the last folder on a bare launch (D88) ----------------------------
# A local core forgets its project on restart, so the GUI remembers the last-opened folder
# in prefs and reopens it at boot (reopen_last_project), which is also what gives the
# workspace restore a root to key on. This is a LOCAL-core feature; this suite attaches over
# a socket (::core_remote 1), so force the local branch for the block — same idiom as the
# drop-routing test above. The core is on loopback, so its paths are ours to stat.
set _rlp_navroot $::nav_root ; set _rlp_remote $::core_remote ; set ::core_remote 0

# Opening a folder on a local core records it as last_project, and it rides prefs.json like
# the other view prefs. (on_project_opened is the open path; call it directly, as the socket
# harness doesn't drive the project.opened event here.)
on_project_opened [dict create root [file normalize $proj]]
ok "reopen: open recorded last_project" $::last_project [file normalize $proj]
set ::last_project "/some/where"
prefs_save ; set ::last_project "" ; prefs_load
ok "reopen: last_project round-trips prefs" $::last_project "/some/where"

# reopen_last_project's branches, isolated from the live core with a project.get stub and an
# open_folder spy (the rename-stub idiom the drop-routing test uses). A project is open now,
# so the guard makes it a no-op — assert that before swapping nav_root out.
set ::_rlp_opened NONE
rename ::open_folder ::_rlp_saved_open_folder
proc ::open_folder {p} { set ::_rlp_opened $p ; return 1 }
reopen_last_project
ok "reopen: no-op when a project is already open" $::_rlp_opened NONE

set ::nav_root ""
rename ::rio_call ::_rlp_saved_rio_call
set ::_rlp_getroot ""
proc ::rio_call {op {params {}}} {
	if {$op eq "project.get"} { return [dict create ok 1 result [dict create root $::_rlp_getroot]] }
	return [::_rlp_saved_rio_call $op $params]
}
# Core has a project already (persistent daemon): adopt it, don't reopen over it.
set ::_rlp_getroot $proj ; set ::_rlp_opened NONE
reopen_last_project
ok "reopen: adopts the core's open project" [list $::nav_root $::_rlp_opened] [list $proj NONE]
# Core has none + a remembered folder that exists: reopen it.
set ::nav_root "" ; set ::_rlp_getroot "" ; set ::_rlp_opened NONE ; set ::last_project $proj
reopen_last_project
ok "reopen: reopens remembered folder when core has none" $::_rlp_opened $proj
# Core has none + the remembered folder has vanished: skip silently AND forget the dead
# pointer so launches stop chasing it (D89).
set ::nav_root "" ; set ::_rlp_opened NONE ; set ::last_project [file join $proj gone-[clock clicks]]
reopen_last_project
ok "reopen: skips a vanished folder" $::_rlp_opened NONE
ok "reopen: clears the pointer to a vanished folder" $::last_project ""
# Remote core: never reopen a local-remembered path against a server we can't stat it on.
set ::nav_root "" ; set ::_rlp_opened NONE ; set ::last_project $proj ; set ::core_remote 1
reopen_last_project
set ::core_remote 0
ok "reopen: no reopen on a remote core" $::_rlp_opened NONE

rename ::rio_call {} ; rename ::_rlp_saved_rio_call ::rio_call
rename ::open_folder {} ; rename ::_rlp_saved_open_folder ::open_folder
set ::nav_root $_rlp_navroot ; set ::core_remote $_rlp_remote
set ::last_project [file normalize $proj]
prefs_save   ;# leave prefs.json matching current state for later tests

# --- the file tree's unfolded shape resumes across a launch (D89) --------------
# ::nav_expanded is saved into the per-project CORE session (workspace.*), so unlike D88's
# project pointer it rides the wire and works in this socket harness as-is (and, in real
# use, follows the project onto a remote host). A project is open here (nav_root = proj).
set ::_exp_sub [file join $::nav_root sub]
# Save: the unfolded set lands in the session and reads back (pruned to dirs that exist).
set ::nav_expanded [dict create $::_exp_sub 1]
session_save
set _exp_got [dict get [rio_call workspace.get {}] result expanded]
ok "unfold: expanded set persists in the core session" \
	[expr {[lsearch -exact $_exp_got $::_exp_sub] >= 0}] 1
# Restore: session_restore refills ::nav_expanded and repaints (the subdir's child shows).
# Stub workspace.get so no real tabs are reopened — we're testing the expand branch only.
rename ::rio_call ::_exp_saved_rio_call
proc ::rio_call {op {params {}}} {
	if {$op eq "workspace.get"} {
		return [dict create ok 1 result [dict create open {} active "" expanded [list $::_exp_sub]]]
	}
	return [::_exp_saved_rio_call $op $params]
}
set ::nav_expanded [dict create]        ;# a fresh launch starts collapsed
session_restore
rename ::rio_call {} ; rename ::_exp_saved_rio_call ::rio_call
ok "unfold: session_restore refills the expanded set" [dict exists $::nav_expanded $::_exp_sub] 1
ok "unfold: the subdir renders unfolded after restore" \
	[expr {[lsearch -exact [nav_payloads] [list file [file join $::_exp_sub inner.txt]]] >= 0}] 1

# --- Edge: the project's own folder vanishes under us (D89) --------------------
# Deleting the open root on disk should CLOSE the project to the placeholder on the next
# repaint — not pop an error dialog (which would also hang a headless run). Force local so
# the last_project clear applies (a remote root is never the remembered local pointer).
set _ed_remote $::core_remote ; set ::core_remote 0
set ::last_project $::nav_root ; set ::nav_expanded [dict create]
set ::_ed_errs 0
rename ::report_error ::_ed_saved_report_error
proc ::report_error {msg {code ""}} { incr ::_ed_errs ; return }
file delete -force $::nav_root
populate_nav
rename ::report_error {} ; rename ::_ed_saved_report_error ::report_error
set ::core_remote $_ed_remote
ok "vanish: a gone root closes to the placeholder" [list $::nav_root [nav_labels]] {{} {{Open a folder…}}}
ok "vanish: no error dialog for a gone root"       $::_ed_errs 0
ok "vanish: forgets the reopen pointer"            $::last_project ""

# The root itself is already gone — the vanish test above deleted it. What is left is the
# TABS still open on files inside it, and those are not harmless: every later stale check
# (D94) rightly asks the user about each vanished file, which in a headless run is a modal
# with nobody to answer it. Close them the way the app would.
sandbox_drop_fixture $proj

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

# --- relative line numbers (gutter modifier) ---------------------------------
# Painted glyphs can't be asserted headless (dlineinfo needs a mapped window, as above),
# so the number FORMULA lives in the pure gutter_label helper and is tested directly:
# absolute when off; with it on, the caret line keeps its absolute number and every other
# line shows its unsigned distance (vim's hybrid number+relativenumber).
ok "relnum: default off"          $::relative_line_numbers        0
ok "relnum: off is absolute"      [gutter_label 7 20 0]           7
ok "relnum: caret line absolute"  [gutter_label 20 20 1]          20
ok "relnum: above caret distance" [gutter_label 17 20 1]          3
ok "relnum: below caret distance" [gutter_label 26 20 1]          6
ok "relnum: distance unsigned"    [gutter_label 1 4 1]            3
# Persisted like the other view toggles (prefs_load reads back what prefs_save wrote).
set ::relative_line_numbers 1 ; prefs_save ; set ::relative_line_numbers 0 ; prefs_load
ok "relnum: pref round-trips"     $::relative_line_numbers        1
set ::relative_line_numbers 0 ; apply_relnum ; prefs_save   ;# restore default for later tests

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
	ok "menu: modified file offers Stage" [menu_labels .tm] \
		[list Open {Copy Path} --- {*}$fsv --- Stage --- {Discard Changes…}]
	# The tree's discard quotes git's own path (repo-root-relative), not the abspath the
	# tree holds, so the confirm reads the same from both doors (D93).
	ok "menu: discard passes the git path" [.tm entrycget end -command] \
		{git_discard_confirm a.txt 0}
	ok "menu: repo path from a nested row" [nav_repo_rel [file join $gdir sub n.txt]] \
		[file join sub n.txt]
	.tm delete 0 end ; nav_menu_build .tm [list file [file join $gdir u.txt]]
	ok "menu: untracked file offers Track" [menu_labels .tm] [list Open {Copy Path} --- {*}$fsv --- {Track (git add)}]
	.tm delete 0 end ; nav_menu_build .tm [list dir [file join $gdir sub]]
	ok "menu: dir with changes offers Stage folder" [menu_labels .tm] [list Open --- {*}$fsv --- {Stage folder}]
	# A file inside a WHOLLY untracked directory: porcelain names only `sub/`, so n.txt is
	# in no status map and the git pane has no row for it. The tree lists it, so the tree
	# is where it gets its door — without this, "add just this one file" was unreachable
	# from either pane.
	.tm delete 0 end ; nav_menu_build .tm [list file [file join $gdir sub n.txt]]
	ok "menu: file under an untracked dir offers Track" [menu_labels .tm] \
		[list Open {Copy Path} --- {*}$fsv --- {Track (git add)}]
	ok "menu: Track adds the file, not its folder" [.tm entrycget end -command] \
		[list do_git add [file join $gdir sub n.txt]]
	# ...and the other direction: a file whose ancestors are all tracked must NOT match, or
	# every clean file in the tree would sprout a Track item.
	ok "menu: a tracked parent is not an untracked one" \
		[nav_untracked_parent $::nav_git [file join $gdir b.txt]] 0
	.tm delete 0 end ; git_menu_build .tm [dict create x { } y M path a.txt]
	ok "menu: git unstaged offers Stage + Discard" [menu_labels .tm] \
		{Open {Copy Path} --- Stage --- {Discard Changes…}}
	.tm delete 0 end ; git_menu_build .tm [dict create x A y { } path c.txt]
	ok "menu: git staged-add offers Unstage + Delete" [menu_labels .tm] \
		{Open {Copy Path} --- Unstage --- Delete…}
	.tm delete 0 end ; git_menu_build .tm [dict create x M y M path a.txt]
	ok "menu: git tracked change offers Discard" [menu_labels .tm] \
		{Open {Copy Path} --- Stage Unstage --- {Discard Changes…}}
	.tm delete 0 end ; git_menu_build .tm [dict create x ? y ? path b.txt]
	ok "menu: git untracked offers Delete" [menu_labels .tm] \
		{Open {Copy Path} --- Stage --- Delete…}
	# The same row for an untracked DIRECTORY — porcelain's trailing slash is the only tell.
	# No Open (file.open on a directory can only error) and the stage item names the folder,
	# because that is what it stages.
	.tm delete 0 end ; git_menu_build .tm [dict create x ? y ? path sub/]
	ok "menu: git untracked dir names the folder" [menu_labels .tm] \
		{{Copy Path} --- {Stage folder} --- Delete…}
	# A rename row still offers Discard, but hands the confirm the ORIGINAL name (D97) —
	# this door is the only one that has it, and the wording promises the old name back.
	.tm delete 0 end ; git_menu_build .tm [dict create x R y { } path r.txt orig a.txt]
	ok "menu: git rename offers Discard" [menu_labels .tm] \
		{Open {Copy Path} --- Unstage --- {Discard Changes…}}
	ok "menu: git rename passes the original name" \
		[.tm entrycget [expr {[.tm index end]}] -command] {git_discard_confirm r.txt 0 a.txt}
	# In the TREE a staged addition offers no discard: discarding a never-committed file
	# removes it, which the fs "Delete…" three entries up already does (D93). ::nav_git is
	# the builder's only input, so drive it directly rather than restage the fixture.
	set _ng $::nav_git
	dict set ::nav_git [file join $gdir a.txt] "A "
	.tm delete 0 end ; nav_menu_build .tm [list file [file join $gdir a.txt]]
	ok "menu: tree staged-add has no discard" [menu_labels .tm] \
		[list Open {Copy Path} --- {*}$fsv --- Unstage]
	set ::nav_git $_ng
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

	# Multi-line commit body (D80): the ＋ toggle reveals a description area; committing
	# joins "summary\n\nbody" (git's subject/blank/body convention).
	proc body_shown {} { expr {[lsearch -exact [pack slaves .pgit.commit] .pgit.commit.body] >= 0} }
	gitc $gdir add u.txt ; refresh_git
	ok "commit: body collapsed by default" [body_shown] 0
	git_commit_body_toggle
	ok "commit: + reveals the body"        [body_shown] 1
	.pgit.commit.msg delete 0 end ; .pgit.commit.msg insert 0 "subject line"
	.pgit.commit.body delete 1.0 end ; .pgit.commit.body insert 1.0 "first body line\nsecond body line"
	git_commit
	ok "commit: subject+body recorded"     [string trim [gitc $gdir log -1 --format=%B]] \
		"subject line\n\nfirst body line\nsecond body line"
	ok "commit: body re-collapses after"   [body_shown] 0

	# Discard all (D93). The ↩ button rides the header and is packed only while the repo
	# has changes; the count it quotes is the length of the list beside it. Then the whole
	# thing end to end through the channel — the op the button calls, past its own modal
	# confirm — which wipes the fixture's working tree, so it goes last.
	proc git_discard_btn {} {
		expr {[lsearch -exact [pack slaves .pgit.hdr] .pgit.hdr.discard] >= 0}
	}
	ok "discard-all: plural of one"    [git_plural 1 change]  change
	ok "discard-all: plural of many"   [git_plural 2 change]  changes
	set gf [open [file join $gdir b.txt] w] ; puts -nonewline $gf "bee\ndirty\n" ; close $gf
	set gf [open [file join $gdir fresh.txt] w] ; puts -nonewline $gf "brand new\n" ; close $gf
	refresh_git
	ok "discard-all: shown while dirty" [git_discard_btn] 1
	ok "discard-all: count is the list" $::git_change_count [llength $::rl_rows(.pgit.well.body)]
	set _n $::git_change_count
	set _r [rio_call git.discard_all {}]
	ok "discard-all: op reported ok"    [expr {[dict get $_r ok] ? 1 : 0}] 1
	ok "discard-all: counted the same"  [dict get $_r result count] $_n
	# The op announces every path it rewrote (D94), so the burst is sitting in the
	# coalescer by the time the reply lands — this is what makes an open buffer able to
	# notice. And a flash drops that idle repaint while the git pane is shown, so the
	# "✓ discarded …" message survives long enough to be read.
	ok "discard-all: announced the paths" [llength $::fs_changed_paths] $_n
	set ::dock_pane git ; git_flash "✓ smoke"
	ok "discard-all: flash drops settle"  [list $::fs_changed_paths $::fs_changed_after] {{} {}}
	refresh_git
	ok "discard-all: repo now clean"    [string trim [git_line 0]] "(clean)"
	ok "discard-all: new file removed"  [file exists [file join $gdir fresh.txt]] 0
	proc gslurp {p} { set f [open $p r] ; set s [::read $f] ; close $f ; return $s }
	ok "discard-all: edit reverted"     [gslurp [file join $gdir b.txt]] "bee\n"
	ok "discard-all: hidden when clean" [git_discard_btn] 0
	ok "discard-all: confirm no-ops at 0" [git_discard_all_confirm] {}

	after cancel refresh_git   ;# drop the pending git_flash restore before teardown
	sandbox_drop_fixture $gdir ;# b.txt is still open on it — close the tab, don't orphan it
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
# chat is the right site's tenant now (D35 c1b): shown = its body packed there. The
# first-run default hides it (no tab), so reveal it before the toggle checks.
proc chat_shown {} { expr {[lsearch -exact [pack slaves .siteright.body] .chat] >= 0} }
panel_reveal chat
ok "chat: reveal shows it"           [chat_shown]  1
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

# The model's reasoning (provider-api 4). Shown muted, marked, and NOT part of the
# answer — a local thinking model can spend a whole short turn in here, so dropping it
# renders an empty reply, while folding it into the deltas would put it in the
# conversation the core re-sends.
proc log_tags {needle} {
	set idx [.chat.log search -- $needle 1.0 end]
	if {$idx eq ""} { return "<not found>" }
	return [.chat.log tag names $idx]
}
chat_clear
chat_event {event agent.thinking params {turn 4 text "first I weigh it up"}}
chat_event {event agent.delta    params {turn 4 text "the answer"}}
chat_event {event agent.message  params {turn 4 role assistant text {the answer}}}
set thlog [.chat.log get 1.0 end]
ok "thinking: it is shown"            [string match "*first I weigh it up*" $thlog] 1
ok "thinking: under one Agent block"  [string match "*Agent*thinking*first I weigh*the answer*" $thlog] 1
ok "thinking: tagged as an aside"     [expr {"thinking" in [log_tags "first I weigh"]}] 1
ok "thinking: the answer is not"      [expr {"thinking" in [log_tags "the answer"]}] 0
ok "thinking: the run closed"         $::chat_thinking_open 0
# Tk invents a tag on first use, so "it carries the tag" would pass with no styling at
# all. What must be true is that the tag was CONFIGURED — muted, and indented so a long
# think reads as an aside even where it wraps.
ok "thinking: the tag is actually styled" \
	[expr {[.chat.log tag cget thinking -foreground] ne ""
		&& [.chat.log tag cget thinking -lmargin2] ne ""}] 1
# And that it is themed, not merely painted once at construction: the default theme's
# gutter.fg is the same #888888 the bootstrap line uses, so comparing colours under the
# default theme proves nothing. Switching is what tells the two sites apart.
do_theme solarized-dark
ok "thinking: follows a theme switch, like every other chat tag" \
	[expr {[.chat.log tag cget thinking -foreground]
		eq [.chat.log tag cget tool -foreground]}] 1
ok "thinking: and actually moved off the bootstrap colour" \
	[expr {[.chat.log tag cget thinking -foreground] ne "#888888"}] 1
do_theme default

# A second run gets its own marker — a multi-step turn thinks between tool calls, and
# one marker for the lot would read as a single train of thought.
chat_clear
chat_event {event agent.thinking params {turn 5 text "hmm"}}
chat_event {event agent.tool     params {turn 5 id t1 name fs_list args path=src}}
chat_event {event agent.thinking params {turn 5 text "now then"}}
chat_event {event agent.message  params {turn 5 role assistant text done}}
ok "thinking: a second run is marked again" \
	[llength [lsearch -all [split [.chat.log get 1.0 end] "\n"] "· thinking"]] 2

# A turn that is nothing but reasoning still opens its block, rather than orphaning the
# muted text under whatever came before.
chat_clear
chat_event {event agent.thinking params {turn 6 text "pondering"}}
ok "thinking: it opens the Agent block itself" \
	[string match "*Agent*thinking*pondering*" [.chat.log get 1.0 end]] 1
chat_clear
ok "thinking: clearing the chat resets the run" $::chat_thinking_open 0
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

# A proposed run_command (D83): the command previews, and the bar is ALWAYS raised —
# even under auto-accept edits — asking to run, with no edit-only Compare button.
proc cmp_shown {} { expr {[lsearch -exact [pack slaves .chat.approve] .chat.approve.cmp] >= 0} }
proc always_shown {} { expr {[lsearch -exact [pack slaves .chat.approve] .chat.approve.always] >= 0} }
chat_clear ; set ::agent_auto_accept 0
chat_event {event agent.propose params {turn 30 id c1 name run_command kind command command {pytest -q} display {pytest -q} cwd ""}}
ok "chat: command preview rendered"   [string match "*\$ pytest -q*" [.chat.log get 1.0 end]] 1
ok "chat: command bar shown"          [bar_shown] 1
ok "chat: command bar asks to run"    [.chat.approve.lbl cget -text] "Run this command?"
ok "chat: command hides Compare"      [cmp_shown] 0
ok "chat: command shows Always allow" [always_shown] 1
ok "chat: command pending turn"       $::pending_turn 30
# cwd is shown when it isn't the project root.
chat_clear
chat_event {event agent.propose params {turn 31 id c2 name run_command kind command command {ls} display {ls} cwd sub/dir}}
ok "chat: command cwd shown"          [string match "*in sub/dir/*" [.chat.log get 1.0 end]] 1
approve_bar 0
# Auto-accept edits must NOT skip a command — the bar still rises.
chat_clear ; set ::agent_auto_accept 1
chat_event {event agent.propose params {turn 32 id c3 name run_command kind command command {rm -rf build} display {rm -rf build} cwd ""}}
ok "chat: command gated despite auto-accept" [bar_shown] 1
ok "chat: command still pending turn"        $::pending_turn 32
approve_bar 0 ; set ::agent_auto_accept 0
# An edit bar after a command restores the edit prompt and the Compare button, and hides
# the command-only Always allow.
chat_clear
chat_event {event agent.propose params {turn 33 id w3 name propose_edit path e.txt diff "+ y"}}
ok "chat: edit bar asks to apply"     [.chat.approve.lbl cget -text] "Apply this edit?"
ok "chat: edit bar restores Compare"  [cmp_shown] 1
ok "chat: edit hides Always allow"    [always_shown] 0
approve_bar 0

# Standing approval (D84): a command carrying auto=1 (covered by an allow-list rule)
# previews but raises NO bar and does not pause the busy indicator — the turn keeps
# working. And the Always-allow menu offers the program first, then the exact command.
chat_clear ; set ::agent_auto_accept 0 ; chat_busy_start
chat_event {event agent.propose params {turn 35 id c5 name run_command kind command command {pytest -q tests/} display {pytest -q tests/} cwd "" auto 1}}
ok "chat: allowed command previews"        [string match "*\$ pytest -q tests/*" [.chat.log get 1.0 end]] 1
ok "chat: allowed command raises no bar"   [bar_shown] 0
ok "chat: allowed command keeps busy"      $::chat_busy 1
chat_busy_stop
# The menu the bar builds for a gated command (D84): two cascades — program (argv[0])
# first, exact second — each opening a scope submenu (all projects / this project /
# provider). Under the default echo provider there is no provider entry, and with no
# project open "This project" is disabled.
chat_clear
chat_event {event agent.propose params {turn 36 id c6 name run_command kind command command {git status -s} display {git status -s} cwd ""}}
ok "chat: allow menu has two cascades"     [.chat.approve.always.m index end] 1
ok "chat: allow menu program cascade"      [.chat.approve.always.m entrycget 0 -label] "Always allow: git"
ok "chat: allow menu exact cascade"        [string match "*this exact command: git status -s*" [.chat.approve.always.m entrycget 1 -label]] 1
ok "chat: program cascade opens a submenu" [.chat.approve.always.m entrycget 0 -menu] .chat.approve.always.m.prog
ok "chat: scope submenu first is global"   [.chat.approve.always.m.prog entrycget 0 -label] "For all projects"
ok "chat: scope submenu no provider (echo)" [.chat.approve.always.m.prog index end] 1
ok "chat: scope submenu second is project"  [.chat.approve.always.m.prog entrycget 1 -label] "For this project only"
approve_bar 0
# The working indicator pauses at a command bar even under auto-accept (waiting on
# the human), where an edit under auto-accept keeps running.
chat_clear ; set ::agent_auto_accept 1 ; chat_busy_start
chat_event {event agent.propose params {turn 34 id c4 name run_command kind command command {make} display {make} cwd ""}}
ok "busy: command pauses at the bar even on auto-accept" $::chat_busy 0
approve_bar 0 ; chat_busy_stop ; set ::agent_auto_accept 0

# The "working" indicator (D82): a turn in flight animates the status strip with a retro
# phrase; it clears when the turn ends and pauses while an approval waits on the user.
chat_clear
ok "busy: idle before any turn"       $::chat_busy 0
chat_busy_start
ok "busy: start sets the flag"        $::chat_busy 1
ok "busy: a real phrase is chosen"    [expr {$::chat_busy_word in $::chat_busy_words}] 1
chat_busy_stop
ok "busy: stop clears the flag"       $::chat_busy 0
ok "busy: idle indicator cleared"     [.chat.status.busy cget -text] ""
# render is a pure function of frame+word: a 1→2→3 "Please wait…" dot cycle.
set ::chat_busy_word "Reticulating splines" ; set ::chat_busy_frame 0 ; chat_busy_render
ok "busy: one dot at frame 0"         [.chat.status.busy cget -text] "Reticulating splines."
set ::chat_busy_frame 2 ; chat_busy_render
ok "busy: three dots at frame 2"      [.chat.status.busy cget -text] "Reticulating splines..."
# The indicator has its own half of the strip (D106): while it animates, the selector
# still says which agent is working — the thing the old one-label strip erased.
ok "busy: the agent is still named"   [string match "Echo*" [.chat.status.sel cget -text]] 1
# A turn ending (message or error) stops the animation.
chat_busy_start ; chat_event {event agent.message params {turn 20 role assistant text hi}}
ok "busy: message ends it"            $::chat_busy 0
chat_busy_start ; chat_event {event agent.error params {turn 21 code x message y}}
ok "busy: error ends it"              $::chat_busy 0

# Stop (D104). There is no step cap any more, so the button that ends a runaway turn is the
# composer's own: ▶ while the turn is yours to type into, ■ while the agent is working.
ok "stop: the idle button sends"      [list [.chat.send cget -text] [.chat.send cget -command]] {▶ chat_send}
chat_busy_start
ok "stop: a working turn offers Stop" [list [.chat.send cget -text] [.chat.send cget -command]] {■ chat_stop}
ok "stop: and says so"                [string match "*Stop*" $::tt_text(.chat.send)] 1
chat_busy_stop
ok "stop: and back to Send"           [.chat.send cget -text] ▶
# The core announces the stop; the transcript line and the indicator come from the EVENT,
# so a stop from another frontend on the same core looks exactly like one from this window.
chat_clear ; chat_busy_start
chat_event {event agent.propose params {turn 23 id s1 name propose_edit path z.txt diff "+ a"}}
set ::pending_turn 23 ; chat_busy_start
chat_event {event agent.stopped params {turn 23}}
ok "stop: the event ends the turn"    $::chat_busy 0
ok "stop: the button is Send again"   [.chat.send cget -text] ▶
ok "stop: the review UI goes with it" [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 0
ok "stop: the transcript says so"     [expr {[string first "· stopped" [.chat.log get 1.0 end]] >= 0}] 1
# Clicking Stop with nothing running is not an error — the click raced the last event.
chat_clear ; chat_busy_start ; chat_stop
ok "stop: a raced click just resets"  $::chat_busy 0
# An approval waiting on the user pauses it; auto-accept keeps it running.
chat_clear ; set ::agent_auto_accept 0 ; chat_busy_start
chat_event {event agent.propose params {turn 22 id p1 name propose_edit path z.txt diff "+ a"}}
ok "busy: pauses at the approval bar" $::chat_busy 0
approve_bar 0
chat_clear ; set ::agent_auto_accept 1 ; chat_busy_start
chat_event {event agent.propose params {turn 23 id p2 name propose_create path z2.txt diff "+ b"}}
ok "busy: keeps running on auto-accept" $::chat_busy 1
chat_busy_stop ; set ::agent_auto_accept 0
# A decision resumes the turn, so the indicator restarts.
chat_clear ; set ::pending_turn 24 ; agent_decide reject
ok "busy: a decision resumes it"      $::chat_busy 1
chat_busy_stop ; set ::pending_turn ""

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

# The working indicator over a real (echo) turn: on at send, off once the reply lands.
chat_clear
.chat.input delete 1.0 end ; .chat.input insert end "ping"
chat_send
ok "busy: on right after send"         $::chat_busy 1
set ::busy_deadline [expr {[clock milliseconds] + 3000}]
while {[clock milliseconds] < $::busy_deadline && $::chat_busy} { update }
ok "busy: off after the reply lands"   $::chat_busy 0

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

# Claude ships as an installable provider (D69), not a built-in — echo is the only
# built-in now. Install the real extension into THIS in-process core's store and
# load it exactly as the core does at startup, so the provider-selection and key-store
# checks below have a real keyed provider to drive. (The GUI install *path* itself is
# exercised with openai further down; here we only need Claude live in the core.)
apply {{dir} {
	set mf [open [file join $dir rio-extension.conf] r] ; fconfigure $mf -encoding utf-8
	set manifest [::read $mf] ; close $mf
	set top [dict get [rio::conf::parse $manifest] ""]
	set files {}
	foreach f [split [dict get $top files]] {
		if {$f eq ""} continue
		set fh [open [file join $dir $f] r] ; fconfigure $fh -encoding utf-8
		dict set files $f [::read $fh] ; close $fh
	}
	rio::provider::put claude $manifest $files
}} [file join [file dirname [info script]] .. .. extensions claude]
rio::provider::load_all
adopt_agent_status

ok "provider: default is echo"        $::agent_provider echo
apply_provider
ok "provider: echo selected in core"  [rio::agent::provider_name] echo
ok "status: names echo agent"         [.chat.status.sel cget -text] "Echo ▾"
set ::agent_provider claude ; apply_provider
ok "provider: claude selected in core" [rio::agent::provider_name] claude
ok "status: names claude agent"       [string match "Claude*" [.chat.status.sel cget -text]] 1
# The mode is NOT in the strip: it is stated once, by the control that sets it (D102).
# Saying it twice was how the old strip came to lie — it showed "plan mode" over an armed
# auto-accept flag it had no room for.
set ::agent_auto_accept 1 ; agent_mode_sync
ok "status: the mode is not repeated here" \
	[string match "*Auto*" [.chat.status.sel cget -text]] 0
ok "status: the control carries it"        [.chat.hdr.mode cget -text] "Auto ▾"
set ::agent_auto_accept 0 ; agent_mode_sync

# --- the agent selector: model and effort, from the pane (D106) --------------
# claude is the live provider here, and it declares two options. NOTHING in the GUI
# names them: the pane renders what the core says the provider declared.
agent_options_refresh
ok "options: the pane lists what the provider declared" [llength $::agent_options] 2
ok "options: the first is the model"   [dict get [lindex $::agent_options 0] name] model
ok "options: a model is free to type"  [dict get [lindex $::agent_options 0] free] 1
ok "options: a model can be refreshed" [dict get [lindex $::agent_options 0] refresh] 1
ok "options: effort is a closed list"  [dict get [lindex $::agent_options 1] free] 0
ok "options: the selector names provider AND model" \
	[string match "Claude · *▾" [.chat.status.sel cget -text]] 1
# Picking writes through the core to the provider, and the label follows.
agent_option_pick model claude-opus-5
ok "options: the provider took the choice" [rio::claude::api::cget model] claude-opus-5
ok "options: the label shows the choice"   [string match "*Opus 5 ▾" [.chat.status.sel cget -text]] 1
ok "options: the choice was remembered"    [rio::agent::settings::get claude model] claude-opus-5
# An option at its default stays out of the label (a 340 px column); a non-default
# one is never invisible.
ok "options: a default option is not spelled out" \
	[string match "*default*" [.chat.status.sel cget -text]] 0
agent_option_pick effort high
ok "options: a non-default option shows"   [string match "*High ▾" [.chat.status.sel cget -text]] 1
ok "options: and would reach the request"  [rio::claude::api::_effort_json] \
	{"output_config":{"effort":"high"}}
agent_option_pick effort default
ok "options: back to default, out of the label again" \
	[string match "*High*" [.chat.status.sel cget -text]] 0
# The menu: a Provider section, then one section per declared option.
proc menu_labels {m} {
	set out {}
	for {set i 0} {$i <= [$m index end]} {incr i} {
		if {[$m type $i] eq "separator"} { lappend out "--" ; continue }
		lappend out [string trim [$m entrycget $i -label]]
	}
	return $out
}
set ::mlabels [menu_labels .chat.status.sel.m]
ok "options: the menu heads a Provider section" [lindex $::mlabels 0] "Provider"
ok "options: and a section per option"          [expr {"Model" in $::mlabels && "Effort" in $::mlabels}] 1
ok "options: a free option offers Other…"       [expr {"Other…" in $::mlabels}] 1
ok "options: a refreshable one offers a refresh" \
	[expr {"⟳ Refresh from provider" in $::mlabels}] 1
ok "options: effort offers neither"             [llength [lsearch -all -exact $::mlabels "Other…"]] 1
# Other…: a value the shipped list never carried (a model newer than this build).
rename name_prompt _real_name_prompt
proc name_prompt {title label prefill} { return "claude-typed-by-hand" }
agent_option_other model
rename name_prompt {} ; rename _real_name_prompt name_prompt
ok "options: a typed value is accepted"    [rio::claude::api::cget model] claude-typed-by-hand
ok "options: and labels itself as typed"   [string match "*claude-typed-by-hand ▾" [.chat.status.sel cget -text]] 1
# A refusal leaves the pane mirroring the core, not its own guess. (report_error is
# captured for the whole suite, above — a modal would hang a headless run.)
set ::captured {}
agent_option_pick effort ludicrous
ok "options: a refused value is reported"  [string match "*must be one of*" $::captured] 1
ok "options: and the pane still shows the core's value" \
	[dict get [agent_option_entry effort] value] "default"
# Refresh with no key: the provider says so rather than calling out (the message rides
# the agent.options event, because the op's reply is long gone by then).
set ::captured {}
agent_option_fetch model
update
ok "options: a keyless refresh explains itself" \
	[string match "*No Claude API key*" $::captured] 1
ok "options: and the choices are untouched" \
	[llength [dict get [agent_option_entry model] choices]] 3
# Refresh: the provider re-enumerates, and the agent.options event repaints the pane.
rio::claude::api::set_key sk-ant-smoke-refresh
set ::claude_fetcher_was $::rio::claude::api::fetcher
set ::rio::claude::api::fetcher [list apply {{req done} {
	{*}$done 200 "" {{"data":[{"id":"claude-fetched","display_name":"Fetched Model"}]}}
}}]
agent_option_fetch model
# The refreshed list arrives as an agent.options event and repaints from the idle
# loop, so give the event loop its turn (bounded, so a regression fails rather than
# hangs).
for {set i 0} {$i < 50 && [llength [dict get [agent_option_entry model] choices]] != 1} {incr i} {
	update ; after 10
}
set ::claude_choices [dict get [agent_option_entry model] choices]
ok "options: a refresh replaced the choices" [llength $::claude_choices] 1
ok "options: with what the provider listed"  [dict get [lindex $::claude_choices 0] label] "Fetched Model"
set ::rio::claude::api::fetcher $::claude_fetcher_was
rio::claude::api::clear_key   ;# the later block checks the keyless error path
# Back to something sane for the rest of the run.
agent_option_pick model claude-sonnet-5

# --- the strip shows only what it can draw and the provider calls quick -------
#
# provider-api 4 lets a provider declare a field (a base URL, a timeout) alongside its
# quick choices. A Tk menu can draw neither a field nor an option the provider marked
# settings-only, and the strip is 340 px wide — so both stay out of it, and the "first
# option is always shown" rule runs over what is left, not over the declaration order.
# The fake deliberately declares the field FIRST, which is the case that would put a URL
# in the strip.
namespace eval stripfake {
	variable url  http://127.0.0.1:1080/v1
	variable mood calm
	variable size big
}
proc stripfake::provider {conversation tools system post} { {*}$post done stop }
proc stripfake::opts {} {
	variable url ; variable mood ; variable size
	return [list \
		[dict create name base_url label "Base URL" value $url kind text group Server] \
		[dict create name size label Size value $size kind choice quick 0 \
			choices {{value big label Big} {value small label Small}}] \
		[dict create name mood label Mood value $mood \
			choices {{value calm label Calm} {value wild label Wild}}]]
}
proc stripfake::opt_set {name value} {
	variable mood
	if {$name ne "mood"} { rio::error::raise bad_request "unknown option: $name" }
	set mood $value
}
rio::agent::register_provider stripfake ::stripfake::provider -label "Strip Fake" \
	-options [dict create list ::stripfake::opts set ::stripfake::opt_set]
providers_menu_fill
set ::agent_provider stripfake ; apply_provider
set ::strip_labels [menu_labels .chat.status.sel.m]
ok "strip: a text option stays out of the menu" [expr {"Base URL" in $::strip_labels}] 0
ok "strip: so does a quick-0 choice"            [expr {"Size" in $::strip_labels}] 0
ok "strip: a quick choice is offered"           [expr {"Mood" in $::strip_labels}] 1
ok "strip: the label names the first QUICK option, not the first declared" \
	[string match "*Calm ▾" [.chat.status.sel cget -text]] 1
ok "strip: and no URL reached those 340 px" \
	[string match "*127.0.0.1*" [.chat.status.sel cget -text]] 0
# The tooltip is the long form, and it is honest about every option, quick or not.
ok "strip: the tooltip still names the field"   [string match "*Base URL*" $::tt_text(.chat.status.sel)] 1
# An unrecognised kind — a provider built against a newer rio — resolves to something
# renderable rather than to a blank: choices mean a chooser, no choices mean a field.
ok "strip: unknown kind with choices draws as a chooser" \
	[agent_option_kind [dict create kind slider choices {{value a label A}}]] choice
ok "strip: unknown kind without choices draws as a field" \
	[agent_option_kind [dict create kind slider choices {}]] text
ok "strip: a missing kind is a chooser"         [agent_option_kind [dict create choices {}]] choice
set ::agent_provider claude ; apply_provider

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
	[string match {*Extensions*Claude*(not_configured)*} [.chat.log get 1.0 end]] 1

# The key is a row in the provider's OWN settings window now (D130), not a modal of
# its own: one window per provider, holding everything that belongs to it. It stores
# and clears through the agent.key.* ops (the core's 0600 store) for the named
# provider, and what it shows comes from the provider's declared metadata
# (agent.providers), so one window serves every keyed provider.
provider_settings_dialog claude
update idletasks
ok "keyrow: the provider's window opens" [winfo exists .provset] 1
ok "keyrow: titled for the provider"  [wm title .provset] "Claude settings"
ok "keyrow: clear disabled w/o key"   [.provset.body.keyb.clear cget -state] disabled
.provset.body.keye insert end "sk-ant-smoke-123"
provider_key_field_save claude
update idletasks
ok "keyrow: the window stays open"    [winfo exists .provset] 1
ok "keyrow: key now stored"           [rio::claude::api::configured] 1
# POSIX-only: `file attributes -permissions` does not exist on Windows (it raises
# "bad option -permissions"), which aborted this whole suite there rather than failing
# one check. rio-core's secret.test/workspace.test already gate the same assertion with
# tcltest's `unix` constraint; this suite has no constraints, so gate it by hand.
if {$::tcl_platform(platform) eq "unix"} {
	ok "keyrow: secret is 0600" \
		[format %04o [expr {[file attributes [file join $::secdir claude-api.secret] -permissions] & 0777}]] 0600
}

# The row repaints from the core, so Clear is live now, and clearing removes the secret.
ok "keyrow: clear enabled with key"   [.provset.body.keyb.clear cget -state] normal
provider_key_field_clear claude
update idletasks
ok "keyrow: key cleared"              [rio::claude::api::configured] 0
destroy .provset

# --- installable providers (D66): openai is no longer built-in, it INSTALLS -----
# A provider is a `kind = provider` extension the core SOURCES at startup. The
# installable-kind gate: provider is a known kind, but one needing a newer
# provider-api than the core loads is greyed (never installable).
ok "prov-kind: provider is a known kind"      [ext_kind_known provider] 1
ok "prov-gate: current provider installable"  [ext_variant_installable {kind provider too_new 0}] 1
ok "prov-gate: too-new provider not installable" [ext_variant_installable {kind provider too_new 1}] 0
ok "prov-gate: row greys when every variant too new" \
	[ext_row_installable [dict create variants [list {kind provider too_new 1}]]] 0

# Prove the GUI install path end to end, offline: build the variant the scanner
# would, stub the fetch seam to serve the shipped openai extension from disk, run
# ext_install (consent stubbed to yes), then load_all — exactly what the core does
# at startup — to activate it in-process (no restart in a test).
set ::oai_srcdir [file join [file dirname [info script]] .. .. extensions openai]
proc _prov_variant {dir source} {
	set mf [open [file join $dir rio-extension.conf] r] ; fconfigure $mf -encoding utf-8
	set manifest [::read $mf] ; close $mf
	set top [dict get [rio::conf::parse $manifest] ""]
	set files {}
	foreach f [split [dict get $top files]] { if {$f ne ""} { lappend files $f } }
	return [dict create source $source dir [file tail $dir] name [dict get $top name] \
		kind provider version [dict get $top version] author [dict get $top author] \
		description "" files $files manifest $manifest \
		api [dict get $top provider-api] entry [dict get $top entry] too_new 0]
}
rename repo_fetch _real_repo_fetch
proc repo_fetch {url {hash 0}} {
	if {[regexp {/([^/]+)$} $url -> f] && [file isfile [file join $::oai_srcdir $f]]} {
		set fh [open [file join $::oai_srcdir $f] r] ; fconfigure $fh -encoding utf-8
		set t [::read $fh] ; close $fh
		return [dict create ok 1 status 200 text $t]
	}
	return [dict create ok 1 status 404 text ""]
}
rename tk_messageBox _real_mb ; proc tk_messageBox {args} { return yes }
set ::prov_installed [ext_install [_prov_variant $::oai_srcdir http://smoke.example/repo]]
rename tk_messageBox {} ; rename _real_mb tk_messageBox
rename repo_fetch {} ; rename _real_repo_fetch repo_fetch

ok "prov-install: ext_install succeeds"   $::prov_installed 1
ok "prov-install: ledger records it"      [dict exists $::ext_ledger provider/openai] 1
set ::prov_names {}
foreach p [dict get [rio_result provider.list {}] providers] {
	lappend ::prov_names [dict get $p name]
}
ok "prov-install: on the core's disk"     [expr {"openai" in $::prov_names}] 1
ok "prov-install: not live before restart" [expr {[lsearch [rio::agent::provider_names] openai] < 0}] 1

# Activate exactly as the core does at its next start, then refresh the picker cache.
rio::provider::load_all
adopt_agent_status

# Now the installed provider (openai / ChatGPT) coexists like any built-in: its own
# label, its own 0600 store, and selecting it names it in the status strip (the
# picker + key dialog are enumerated from the core, so it needed no GUI change).
ok "provider: openai now in the picker cache" \
	[expr {[agent_provider_entry openai] ne ""}] 1
set ::agent_provider openai ; apply_provider
ok "provider: openai selected in core" [rio::agent::provider_name] openai
ok "status: names the provider"       [string match "OpenAI-compatible*" [.chat.status.sel cget -text]] 1
provider_settings_dialog openai
update idletasks
ok "keyrow: titled for openai"         [wm title .provset] "OpenAI-compatible settings"
ok "keyrow: openai has its own door"   [expr {"OpenAI-compatible…" in [ext_menu_labels]}] 1
.provset.body.keye insert end "sk-oai-smoke-123"
provider_key_field_save openai
update idletasks
ok "keyrow: openai key stored"         [rio::openai::api::configured] 1
ok "keyrow: claude key still absent"   [rio::claude::api::configured] 0
provider_key_field_clear openai
update idletasks
ok "keyrow: openai key cleared"        [rio::openai::api::configured] 0
destroy .provset

# --- Agent Prompts dialog (Preferences ▸ Agent ▸ Agent Prompts…, D70) ---------
# The dialog opens the two user-editable system-prompt files in rio's editor; the core
# owns and creates them (agent.prompt.edit). Its door is the Preferences Agent pane now
# (not the Settings menu — jka, 2026-09-09); dialog builds, its project button tracks
# whether a project is open, and editing the system prompt resolves+creates system.md
# (in the sandbox XDG) and opens it as a tab.
ok "menu: Agent Prompts… no longer in Settings" \
	[catch {.m.settings index "Agent Prompts…"}] 1
agent_prompts_dialog
ok "prompts: dialog opens"               [winfo exists .agentprompts] 1
ok "prompts: system button enabled"      [.agentprompts.sys cget -state] normal
set ::pr_root [dict get [rio_result project.get {}] root]
ok "prompts: project button tracks state" [.agentprompts.proj cget -state] \
	[expr {$::pr_root ne "" ? "normal" : "disabled"}]
set ::nbuf_before [dict size $::buffers]
agent_prompt_open system
ok "prompts: dialog closed after open"   [winfo exists .agentprompts] 0
ok "prompts: system.md opened in a tab"  [expr {[dict size $::buffers] > $::nbuf_before}] 1
ok "prompts: opened buffer is system.md" [string match {*system.md} [bufget $::cur path]] 1

# The per-provider row (D79): with a real provider registered (openai, live above), the
# chooser + Edit button appear and default to a non-echo provider; editing resolves+creates
# providers/<name>.md in the sandbox XDG and opens it as a tab.
agent_prompts_dialog
ok "prompts: provider row present"        [winfo exists .agentprompts.prov.edit] 1
ok "prompts: chooser defaults non-echo"   [expr {$::agent_prompt_provider ni {echo {}}}] 1
set ::agent_prompt_provider openai
set ::nbuf_before2 [dict size $::buffers]
agent_prompt_open provider $::agent_prompt_provider
ok "prompts: provider dialog closed"      [winfo exists .agentprompts] 0
ok "prompts: providers/openai.md in a tab" [string match {*providers/openai.md} [bufget $::cur path]] 1

# rio's OWN two layers are on the same list, and readable (D105). The dialog lists every
# layer in composition order — including the shipped base and plan-mode prompts, which
# have a View door rather than an Edit one — plus the composed whole. The state word comes
# from the core's inventory: system.md was created empty by the block above, so it exists
# and says nothing, which is a different state from "not created yet".
agent_prompts_dialog
ok "prompts: base row present"            [winfo exists .agentprompts.base] 1
ok "prompts: plan row present"            [winfo exists .agentprompts.plan] 1
ok "prompts: whole-prompt row present"    [winfo exists .agentprompts.full] 1
ok "prompts: base reads as rio's"         [.agentprompts.base cget -text] "View rio's instructions…"
ok "prompts: base layer is shipped"       [prompt_layer_field base origin] shipped
ok "prompts: base layer is in effect"     [prompt_state_word base] "in effect now"
ok "prompts: empty system layer says so"  [prompt_state_word system] "empty"
ok "prompts: plan layer waits for plan mode" [prompt_state_word plan] "not in effect now"

# The viewer: rendered, read-only, and honest about where the text came from.
prompt_view base
ok "promptview: opens"                    [winfo exists .promptview] 1
ok "promptview: read-only"                [.promptview.body.t cget -state] disabled
set ::pv_text [.promptview.body.t get 1.0 end]
ok "promptview: shows rio's instructions" [string match {*rio's coding agent*} $::pv_text] 1
ok "promptview: rendered, not dumped"     [string match {*#*} $::pv_text] 0
ok "promptview: names the shipped file"   [string match {Shipped with rio: *prompt.md*} \
	[.promptview.where cget -text]] 1
ok "promptview: offers a copy"            [winfo exists .promptview.btns.copy] 1
destroy .promptview

# The composed view is the one that cannot mislead: the joined text, and nothing to copy.
prompt_view composed
ok "promptview: composed has no copy"     [winfo exists .promptview.btns.copy] 0
ok "promptview: composed joins the base"  [string match {*rio's coding agent*} \
	[.promptview.body.t get 1.0 end]] 1
destroy .promptview

# Making your own copy: the core seeds the override with the text that was in effect, it
# opens as an ordinary tab, and the list then describes the new truth.
set ::nbuf_before3 [dict size $::buffers]
prompt_view base
prompt_view_copy base
ok "promptview: copy closed the viewer"   [winfo exists .promptview] 0
ok "promptview: copy opened a tab"        [expr {[dict size $::buffers] > $::nbuf_before3}] 1
ok "promptview: the tab is the override"  [string match {*agent/prompt.md} [bufget $::cur path]] 1
set ::pv_override [bufget $::cur path]
ok "promptview: the copy is seeded"       [string match {*rio's coding agent*} [buf_text $::cur]] 1
agent_prompts_dialog
ok "prompts: override reads as mine"      [prompt_layer_field base origin] user
ok "prompts: base row becomes an editor"  [.agentprompts.base cget -text] "Edit your copy…"
destroy .agentprompts
# Put the sandbox back to shipped, so nothing later in the run reads a forked base.
close_buffers_under [file dirname $::pv_override]
file delete -force $::pv_override
agent_prompts_dialog
ok "prompts: deleting the copy restores rio's" [prompt_layer_field base origin] shipped
destroy .agentprompts

# The Extensions window's detail must WORD-WRAP a long description, not stretch the
# auto-sized window. No repository is configured in the sandbox, so the window opens
# on an empty scan; drive extw_select with a synthetic long-description row and check
# the description label is wrap-bounded to the list's width.
extensions_window
set ::longdesc [string repeat "verylongword " 40]
set ::extw_rows [list [dict create name openai kind provider desc $::longdesc \
	key provider/openai variants [list [dict create source http://h/repo dir openai \
		name openai kind provider version 1.0 author jlsksr description $::longdesc \
		files openai.tcl manifest "" api 1 entry openai.tcl too_new 0]]]]
.extw.body.list delete 0 end
.extw.body.list insert end "openai   provider"
.extw.body.list selection set 0
extw_select
ok "extw: description label wraps"        [expr {[.extw.det.head cget -wraplength] > 0}] 1
ok "extw: long desc doesn't stretch window" \
	[expr {[winfo reqwidth .extw.det.head] <= [winfo reqwidth .extw.body.list]}] 1
destroy .extw

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
# The Compare top-level menu (D73) exposes both entry points (D74): Another Tab and A File.
# Compare left the View ▸ Editor Layout submenu, and the old top-level Tabs menu is retired —
# reaching a tab by name is now View ▸ Switch to Tab… (D74).
ok "compare: menu has tab entry"    [expr {![catch {.m.compare index "Compare With Another Tab…"}]}] 1
ok "compare: menu has file entry"   [expr {![catch {.m.compare index "Compare With A File…"}]}] 1
ok "compare: menu has close"        [expr {![catch {.m.compare index "Close Compare"}]}] 1
ok "compare: not in Editor Layout"  [expr {[catch {.m.view.layout index "Compare With A File…"}]}] 1
ok "tabs: top-level menu retired"   [winfo exists .m.tabs] 0
ok "tabs: Switch to Tab… in View"   [expr {![catch {.m.view index "Switch to Tab…"}]}] 1
# The search cluster is its own top-level Find menu now (D75), not under Edit.
ok "find: menu has Find…"           [expr {![catch {.m.find index "Find…"}]}] 1
ok "find: menu has Search…"         [expr {![catch {.m.find index "Search…"}]}] 1
ok "find: Find… gone from Edit"     [expr {[catch {.m.edit index "Find…"}]}] 1
# Help ▸ About rio shows the version, the build id + its commit date (D76, D123): the menu
# exists, each resolves to a non-empty string, and the modal builds with them on screen.
#
# The rows are looked up BY LABEL, not by index. D121 had to append `License` last on
# purpose to keep positional assertions meaning what they said; D123 put `Version` first,
# which is where it belongs, so the fragility goes rather than the row order bending
# around it. What the box is asserted to say no longer depends on where it says it.
proc about_fact {label} {
	for {set r 0} {[winfo exists .about.facts.k$r]} {incr r} {
		if {[.about.facts.k$r cget -text] eq $label} { return [.about.facts.v$r cget -text] }
	}
	return ""
}
ok "help: About rio in Help menu"   [expr {![catch {.m.help index "About rio"}]}] 1
ok "help: build id non-empty"       [expr {[string length [rio_build_id]] > 0}] 1
ok "help: build date non-empty"     [expr {[string length [rio_build_date]] > 0}] 1
about_dialog
ok "help: About modal built"        [winfo exists .about] 1
ok "help: About shows the version"  [about_fact Version] $rio::version
ok "help: About shows the build id" [expr {[string first [rio_build_id] [about_fact Build]] >= 0}] 1
ok "help: About shows the date"     [expr {[string first [rio_build_date] [about_fact Date]] >= 0}] 1
# Version and Build are different facts and both earn their row: the release line, and the
# exact commit under it. A build that reported the same string for both would mean one of
# them had quietly become the other.
ok "help: Version is not the build id" [expr {[about_fact Version] ne [about_fact Build]}] 1
# …and the licence (D121). The name is written in the dialog, so the guard is against the
# LICENSE file itself rather than against a second copy of the string: relicense the project
# and forget the About box, and this fails by name. Both halves are checked — the row is
# labelled License, and what it names is the licence the file grants.
set _lic_first ""
set _lic_fh [open [file join [file dirname [info script]] .. .. LICENSE] r]
gets $_lic_fh _lic_first
close $_lic_fh
ok "help: About has a License row"  [expr {[about_fact License] ne ""}] 1
ok "help: …the one LICENSE grants"  [expr {[string first [about_fact License] $_lic_first] >= 0}] 1
unset _lic_first _lic_fh
# The About box wears rio's own icon (D117), left of the name. It REUSES an image
# apply_window_icon already loaded for `wm iconphoto` rather than reading the file again,
# so the box cannot drift from the icon rio is actually wearing — asserted by identity,
# not by looking at a file.
ok "help: About shows rio's icon"   [winfo exists .about.icon] 1
ok "help: …the very image the window manager was given, not a second read" \
	[expr {[.about.icon cget -image] in [info commands ::rio_icon_*]}] 1
ok "help: …and the text sits beside it, in column 1" \
	[list [dict get [grid info .about.icon] -column] [dict get [grid info .about.name] -column]] {0 1}
destroy .about
# Absent-safe, the D117 soft case: with no icon images the box drops the icon and keeps its
# old single-column look. The text stays in column 1, whose column 0 is then simply empty —
# one layout, not two to hold in step.
set _icon_cmds [info commands ::rio_icon_*]
rename ::rio_icon_64 ::_saved_icon_64
foreach _i {32 48} { catch {rename ::rio_icon_$_i ::_saved_icon_$_i} }
about_dialog
ok "help: About builds with no icon at all"   [winfo exists .about] 1
ok "help: …and shows no icon label"           [winfo exists .about.icon] 0
ok "help: …with the text where it always was" [dict get [grid info .about.name] -column] 1
destroy .about
rename ::_saved_icon_64 ::rio_icon_64
foreach _i {32 48} { catch {rename ::_saved_icon_$_i ::rio_icon_$_i} }
ok "help: the icon images are back for later checks" \
	[expr {[llength [info commands ::rio_icon_*]] == [llength $_icon_cmds]}] 1
# Compare With Another Tab… diffs the active buffer against another open buffer, both sides
# live buffer text (D74). Drive compare_with_tab directly (the modal picker's row-building is
# covered by buffer_pick_rows in tabs.tcl); open two buffers so there's another tab to pick.
set _fa [tmpbytes "one\ntwo\n"] ; do_open $_fa ; set _ta $::cur
set _fb [tmpbytes "one\nTWO\n"] ; do_open $_fb ; set _tb $::cur   ;# _tb is now active
compare_with_tab $_ta
ok "compare tab: shown flag set"    $::compare_shown 1
ok "compare tab: left is current"   [.cmp.l.hdr cget -text] "[tab_name $_tb] (current)"
ok "compare tab: right is picked"   [.cmp.r.hdr cget -text] "[tab_name $_ta]"
ok "compare tab: a change tagged"   [expr {[llength [.cmp.r.t tag ranges add]] > 0}] 1
compare_close
# The View menu is kept short enough to fit on screen by grouping less-used items into
# topical submenus (D64): a Tk menu taller than the space below it misbehaves on X11. Guard
# the top-level length and the submenus so a future addition can't quietly re-inflate it.
ok "view: top level stays short"    [expr {[.m.view index end] <= 20}] 1
ok "view: Dock Side submenu"        [expr {[winfo exists .m.view.dock] && [.m.view.dock index "Left"] ne ""}] 1
ok "view: Font & Zoom submenu"      [expr {[winfo exists .m.view.zoom] && [.m.view.zoom index "Zoom In"] ne ""}] 1
ok "view: Editor Layout submenu"    [expr {[winfo exists .m.view.layout] && [.m.view.layout index "Split Editor"] ne ""}] 1
# Extensions has its own top-level menu (D130): the installer leads it, and below the
# separator sits one door per installed extension that has something to configure. It
# was under View until D67 and under Settings until D130; both moves have to stay made,
# so assert all three places. These are direct assertions rather than a docs-path check:
# .m.extensions is data-filled (docs.tcl exempts it as a ::datamenu), so this suite is
# where the installer's own entry is held. (The three helpers are defined near the top,
# so the openai-provider block above can use them too.)
ok "menu: the menubar's order" [menubar_labels] \
	{File Edit View Find Compare Settings Extensions Help}
# "Browse…", not "Extensions…": the menu and the window it opens are both called
# Extensions, so the entry names the act rather than stuttering the noun.
ok "menu: Browse… leads its own menu" [lindex [ext_menu_labels] 0] "Browse…"
ok "menu: and opens the installer" \
	[.m.extensions entrycget [.m.extensions index "Browse…"] -command] extensions_window
ok "menu: the installer is gone from Settings" \
	[list [_menu_has_label .m.settings "Extensions…"] [_menu_has_label .m.settings "Browse…"]] {0 0}
ok "menu: and gone from View" \
	[list [_menu_has_label .m.view "Extensions…"] [_menu_has_label .m.view "Browse…"]] {0 0}
# The Theme cascade was the last data-driven menu with no size bound — it grew with every
# installed theme and could post taller than the screen (CAVEATS.md). D92 retired it into
# the bounded picker, the way D74 retired the Tabs cascade: a command, never a cascade.
ok "view: Theme… is a command"      [.m.view type "Theme…"] command
ok "view: no Theme cascade left"    [winfo exists .m.view.theme] 0
ok "view: Theme… opens the picker"  [.m.view entrycget "Theme…" -command] theme_pick_dialog
# The Preferences window mirrors the menu with its own Extensions… button (D67/D130).
preferences_window
ok "prefs: has an Extensions… button"  [expr {[winfo exists .prefs.btns.ext] \
	&& [.prefs.btns.ext cget -text] eq "Extensions…"}] 1
destroy .prefs
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
# dock_side=right + chat off: files/git unify into the right site (decision 1a), git is
# the active pane; the dock shows, but the Agent tab is hidden (chat_shown=0) — per-pane
# now, so the SITE stays visible for the dock rather than the whole thing collapsing.
set mr [rio::layout::normalize [rio::layout::migrate {dock_side right dock_pane git chat_shown 0}]]
ok "layout: migrate dock to right" [expr {"files" in [dict get $mr sites right panels] && "git" in [dict get $mr sites right panels]}] 1
ok "layout: migrate active git"    [dict get $mr sites right active] git
ok "layout: migrate chat hidden"   [expr {"chat" in [dict get $mr sites right hidden]}] 1
ok "layout: migrate dock shown"    [dict get $mr sites right visible] 1
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

# panel_toggle is the View-menu show/hide path — "hide" means NO TAB at all. A solo
# pane (chat in right) loses its tab, collapsing its site; toggling again brings it back.
panel_toggle chat
ok "toggle: chat hides"             [list [rio::layout::shown chat] $::shown_chat [rio::layout::get right visible]] {0 0 0}
panel_toggle chat
ok "toggle: chat shows again"       [list [rio::layout::shown chat] $::shown_chat [rio::layout::get right visible]] {1 1 1}
# A SHARED site (files+git on the left): both shown, hide one -> its tab goes, the
# sibling keeps the dock open. Hide the LAST shown pane too -> the whole dock collapses
# (the per-pane hide the old foreground-switch model couldn't do). Reveal brings it back.
panel_reveal files ; panel_reveal git      ;# both have tabs
panel_toggle files
ok "toggle: hidden pane loses its tab" [list [rio::layout::shown files] [tabs_of left]] {0 git}
ok "toggle: dock stays on sibling"     [list [rio::layout::get left visible] [rio::layout::get left active]] {1 git}
panel_toggle git
ok "toggle: last hide collapses dock"  [list [rio::layout::shown git] [rio::layout::get left visible]] {0 0}
panel_reveal files
ok "toggle: reveal reopens dock"       [list [rio::layout::shown files] [rio::layout::get left visible]] {1 1}

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
# dock git into the bottom site beside search; the left site drops to one tab. Both
# bottom panes are shown (hidden {}) so both get a tab.
dict set ::layout sites bottom panels {search git}
dict set ::layout sites bottom hidden {}
dict set ::layout sites bottom active search
dict set ::layout sites left   panels {files}
dict set ::layout sites left   hidden {}
set ::layout [rio::layout::normalize $::layout]
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

# --- D117: the window / taskbar icon -------------------------------------------
# A soft asset, like tkdnd (D86): rio must start with the icons absent. The sizes the
# loader asks for and the files on disk are held against each other BOTH ways, so a
# size added to one and not the other fails here rather than silently falling back to
# the window manager's default — which looks like nothing being wrong.
set _icodir [file join $::rio_dir icons]
set _asked $::icon_sizes
ok "icon: the loader asks for a set of sizes" [expr {[llength $_asked] > 0}] 1
set _ondisk {}
foreach _f [lsort [glob -nocomplain -directory $_icodir rio-*.png]] {
	if {[regexp {rio-([0-9]+)\.png$} $_f -> _n]} { lappend _ondisk $_n }
}
ok "icon: every size asked for is on disk, and every file is asked for" \
	[lsort -integer $_ondisk] [lsort -integer $_asked]
set _loaded [lsort [info commands ::rio_icon_*]]
ok "icon: one photo image per size was created" [llength $_loaded] [llength $_asked]
set _sq 1
foreach _i $_loaded { if {[image width $_i] != [image height $_i]} { set _sq 0 } }
ok "icon: every image is square (a window manager scales, it does not letterbox)" $_sq 1
ok "icon: the 16px one is really 16px — the title-bar size, cut not scaled" \
	[list [image width ::rio_icon_16] [image height ::rio_icon_16]] {16 16}
# Absent-safe: point the loader at a directory with no icons and rio carries on.
set _realdir $::rio_dir
set ::rio_dir [file join / nonexistent-rio-icon-check-[pid]]
ok "icon: a checkout with no icons/ still starts (soft, like tkdnd)" [catch {apply_window_icon}] 0
set ::rio_dir $_realdir

# --- D125: a huge or binary file asks before it opens ---------------------------
# The core declines (fs.test proves that half); what matters here is that the GUI
# turns the refusal into a QUESTION rather than an error box, and that answering it
# actually opens the file. The message box is stubbed to record what it was asked and
# to answer on cue — the one way a modal can be tested headless.
set _mb_msg "" ; set _mb_type "" ; set _mb_answer no
rename tk_messageBox _real_mb
proc tk_messageBox {args} {
	set ::_mb_msg  [dict get $args -message]
	set ::_mb_type [expr {[dict exists $args -type] ? [dict get $args -type] : ""}]
	return $::_mb_answer
}

set _bigfile [tmpbytes [string repeat "x" 4000]]
set _before [dict size $::buffers]

# Shrink the core's budget for the duration. The core is in this process (the smoke
# suite hosts its own server), so the variable is reachable — a remote core would need
# a fixture file instead, which is the reason the core-side tests carry the real proof.
set _saved_budget $rio::ops::open_max_bytes
set rio::ops::open_max_bytes 1000

set ::_mb_answer no
set _opened [do_open $_bigfile]
ok "bigfile: a file over the budget is refused, not opened" $_opened 0
ok "bigfile: rio ASKED rather than reporting an error" $::_mb_type yesno
ok "bigfile: the question carries the core's own sentence, size and all" \
	[string match "*4 KB*Open it anyway?*" $::_mb_msg] 1
ok "bigfile: the question names the file and offers the way past" \
	[string match "*[file tail $_bigfile]*Open it anyway?*" $::_mb_msg] 1
ok "bigfile: declining opened no buffer" [dict size $::buffers] $_before

set ::_mb_answer yes
set _opened [do_open $_bigfile]
ok "bigfile: saying yes opens it" $_opened 1
ok "bigfile: and it really is in a buffer" [dict size $::buffers] [expr {$_before + 1}]
ok "bigfile: a forced open starts as Plain Text — the highlighter is the other\
	half of the slowness (D112's own value, so View ▸ Language… can undo it)" \
	[bufget $::cur lang] plain
ok "bigfile: the text arrived whole" [string length [widget]] 4000

close_buffer $::cur
set rio::ops::open_max_bytes $_saved_budget

# A binary file takes the same road, under its own code.
set _binfile [tmpbytes "\x7FELF\x02\x00\x00\x00 payload here"]
set ::_mb_answer no ; set ::_mb_msg ""
ok "binary: a binary file is refused too" [do_open $_binfile] 0
ok "binary: and the question says binary, not big" \
	[string match "*binary*" $::_mb_msg] 1
set ::_mb_answer yes
ok "binary: force opens it" [do_open $_binfile] 1
close_buffer $::cur

# The common case must not have acquired a dialog.
set ::_mb_msg ""
set _plain [tmpbytes "ordinary source\n"]
ok "guard: an ordinary file opens with no question at all" \
	[list [do_open $_plain] $::_mb_msg] {1 {}}
close_buffer $::cur
rename tk_messageBox {} ; rename _real_mb tk_messageBox

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

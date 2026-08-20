#!/usr/bin/env wish
#
# Headless editing-modes test for rio-gui (AGENTS.md D38): the RioMode bind-tag
# layer, the registry + loader (drop-ins, later-wins, broken module skipped), the
# Windows mode's clipboard/word-delete behaviour flowing through the core, the
# Emacs mode's added motions, the Ctrl-V regression (paste vs page-scroll), the
# prefs round-trip and the unknown-mode fallback. The vi engine has its own suite
# (vi.tcl). Needs a DISPLAY (Tk); shows no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/modes.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31)
sandbox_install_mode emacs ;# D41: emacs/vi ship as extensions, not in the core
sandbox_install_mode vi
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

# Fire a RioMode binding the way a keypress would: eval the REAL bound script with
# %W substituted. A trailing `break` raises code 3 outside a bind context — that is
# the binding doing its job, not an error.
proc fire {chord} {
	set script [bind RioMode $chord]
	if {$script eq ""} { return "unbound" }
	set script [string map [list %W [gget $::focus path]] $script]
	set rc [catch {uplevel #0 $script} err]
	if {$rc == 0 || $rc == 3} { return ok }
	return "error: $err"
}

proc clear_buf {} { .ed.t delete 1.0 "end -1c" }
proc set_clip {txt} { clipboard clear ; clipboard append $txt }

# --- boot state: windows mode attached, tag layered correctly ------------------
ok "boot: default mode"          $::edit_mode        windows
ok "boot: mode attached"         $::editmode_active  windows
ok "boot: tag after widget path" [lindex [bindtags [gget 0 path]] 1] RioMode
ok "boot: app chord still bound" [expr {[bind [gget 0 path] <Control-n>] ne ""}] 1
ok "boot: mode chord bound"      [expr {[bind RioMode <Control-a>] ne ""}] 1
ok "boot: emacs leftover dead"   [bind RioMode <Control-k>] break
ok "boot: menu has the modes"    [expr {[.m.settings.editmode index end] >= 2}] 1

# --- windows mode: clipboard + select-all, edits flow through the core ---------
clear_buf
.ed.t insert insert "hello world"
ok "win: typed through core"  [buf_text $::cur] "hello world"

ok "win: select-all fires"    [fire <Control-a>] ok
ok "win: select-all range"    [rio_real_t get sel.first sel.last] "hello world"

ok "win: copy fires"          [fire <Control-c>] ok
ok "win: copy on clipboard"   [clipboard get] "hello world"

# paste replaces the selection as ONE core edit (the proxy's replace arm): a
# single undo brings the selected text back.
set_clip "bye"
rio_real_t tag remove sel 1.0 end
rio_real_t tag add sel 1.0 1.5           ;# select "hello"
ok "win: paste fires"          [fire <Control-v>] ok
ok "win: paste replaced sel"   [buf_text $::cur] "bye world"
do_undo
ok "win: replace is one undo"  [buf_text $::cur] "hello world"

# cut removes through the core and loads the clipboard
rio_real_t tag remove sel 1.0 end
rio_real_t tag add sel 1.6 1.11          ;# select "world"
ok "win: cut fires"            [fire <Control-x>] ok
ok "win: cut removed text"     [buf_text $::cur] "hello "
ok "win: cut on clipboard"     [clipboard get] "world"

# Ctrl+Backspace eats the previous word
clear_buf
.ed.t insert insert "alpha beta"
.ed.t mark set insert "1.0 lineend"
ok "win: word-back fires"      [fire <Control-BackSpace>] ok
ok "win: word-back result"     [buf_text $::cur] "alpha "

# Ctrl+Delete eats to the next word start
.ed.t mark set insert 1.0
ok "win: word-fwd fires"       [fire <Control-Delete>] ok
ok "win: word-fwd result"      [buf_text $::cur] ""

# --- windows mode: Tab / Shift+Tab block-indent, keeping each line's whitespace --
clear_buf
.ed.t insert insert "a\n\tb\n  c"
rio_real_t tag remove sel 1.0 end
rio_real_t tag add sel 1.0 "end -1c"      ;# select all three lines
ok "win: indent fires"          [fire <Tab>] ok
ok "win: indent keeps ws"       [buf_text $::cur] "\ta\n\t\tb\n\t  c"
ok "win: selection not deleted"  [expr {[llength [rio_real_t tag ranges sel]] > 0}] 1
fire <Tab>                                 ;# a second Tab adds another level to the block
ok "win: indent repeats"        [buf_text $::cur] "\t\ta\n\t\t\tb\n\t\t  c"
do_undo
ok "win: indent is one undo"    [buf_text $::cur] "\ta\n\t\tb\n\t  c"
rio_real_t tag remove sel 1.0 end          ;# undo doesn't restore the selection; re-make it
rio_real_t tag add sel 1.0 "end -1c"
fire <Shift-Tab>                           ;# dedent one level: a leading tab off each line
ok "win: dedent a level"        [buf_text $::cur] "a\n\tb\n  c"
fire <Shift-Tab>                           ;# tabs gone, now up to a tab-stop of spaces
ok "win: dedent spaces too"     [buf_text $::cur] "a\nb\nc"

# a wholly blank line isn't grown into trailing whitespace
clear_buf
.ed.t insert insert "x\n\ny"
rio_real_t tag remove sel 1.0 end
rio_real_t tag add sel 1.0 "end -1c"
fire <Tab>
ok "win: blank line untouched"  [buf_text $::cur] "\tx\n\n\ty"

# a selection ending at column 0 leaves that trailing line alone
clear_buf
.ed.t insert insert "p\nq\nr"
rio_real_t tag remove sel 1.0 end
rio_real_t tag add sel 1.0 3.0
fire <Tab>
ok "win: col-0 line excluded"   [buf_text $::cur] "\tp\n\tq\nr"

# no selection: Tab inserts a plain tab; Shift+Tab dedents the caret's line
clear_buf
.ed.t insert insert "z"
.ed.t mark set insert 1.0
rio_real_t tag remove sel 1.0 end
fire <Tab>
ok "win: no-sel Tab inserts"     [buf_text $::cur] "\tz"
fire <Shift-Tab>
ok "win: no-sel Shift dedents"   [buf_text $::cur] "z"

# --- windows mode: column / block editing (D40) ------------------------------
# Drive the model directly (headless can't post real Ctrl+Shift mouse drags): set
# ::col_* state, then exercise the same procs the bindings call.
set W [gget $::focus path]
set ::col_on 1

# zero-width caret column: a typed char lands at the column on every spanned line
clear_buf
.ed.t insert insert "abc\nde\nfghij"
set ::col_w $W ; set ::col_anchor 1.1 ; set ::col_caret 3.1 ; set ::col_active 1
ok "col: here on the widget"    [col_here $W] 1
ok "col: typed consumed"        [col_typed $W X 0] 1
ok "col: type down the column"  [buf_text $::cur] "aXbc\ndXe\nfXghij"
do_undo
ok "col: one undo reverts all"  [buf_text $::cur] "abc\nde\nfghij"

# short lines are space-padded to reach the column (virtual space)
clear_buf
.ed.t insert insert "abcdef\ngh\nijklmn"
set ::col_w $W ; set ::col_anchor 1.4 ; set ::col_caret 3.4 ; set ::col_active 1
col_typed $W Z 0
ok "col: pads short lines"       [buf_text $::cur] "abcdZef\ngh  Z\nijklZmn"

# a width>0 block: typing overwrites that rectangular slice on each line
clear_buf
.ed.t insert insert "HELLO\nworld\nabcde"
set ::col_w $W ; set ::col_anchor 1.1 ; set ::col_caret 3.3 ; set ::col_active 1
col_typed $W _ 0
ok "col: block overwrite"        [buf_text $::cur] "H_LO\nw_ld\na_de"

# Delete removes the char at the column on each line; Backspace the one before it
clear_buf
.ed.t insert insert "aXbc\ndXe\nfXg"
set ::col_w $W ; set ::col_anchor 1.1 ; set ::col_caret 3.1 ; set ::col_active 1
col_key $W delfwd
ok "col: delete fwd per line"    [buf_text $::cur] "abc\nde\nfg"
clear_buf
.ed.t insert insert "aXbc\ndXe\nfXg"
set ::col_w $W ; set ::col_anchor 1.2 ; set ::col_caret 3.2 ; set ::col_active 1
col_key $W delback
ok "col: backspace per line"     [buf_text $::cur] "abc\nde\nfg"

# Tab types a tab down the whole column
clear_buf
.ed.t insert insert "a\nb\nc"
set ::col_w $W ; set ::col_anchor 1.0 ; set ::col_caret 3.0 ; set ::col_active 1
col_edit insert \t
ok "col: tab down the column"    [buf_text $::cur] "\ta\n\tb\n\tc"

# zero-width caret column paints thin blinking bars, not the old solid block: the
# native insert bar is hidden (insertwidth 0) while it's live, and the colcaret tag
# is gone. col_clear restores the native bar. (bbox is empty under headless, so the
# placed bars themselves can't be counted here — the insertwidth swap is the proxy.)
clear_buf
.ed.t insert insert "a\nb\nc"
set ::col_w $W ; set ::col_anchor 1.0 ; set ::col_caret 3.0 ; set ::col_active 1
col_paint
ok "col: native bar hidden"      [$W cget -insertwidth] 0
ok "col: no colcaret tag"        [lsearch -exact [$W tag names] colcaret] -1
col_clear
ok "col: native bar restored"    [expr {[$W cget -insertwidth] > 0}] 1

# a width selection keeps the native bar (rectangular coltag band, not a caret)
set ::col_w $W ; set ::col_anchor 1.0 ; set ::col_caret 3.2 ; set ::col_active 1
col_paint
ok "col: width keeps native bar" [expr {[$W cget -insertwidth] > 0}] 1
col_clear

# guards: Ctrl-modified keys aren't typed; an inactive selection ignores keys;
# and with the pref off the gesture is inert
set ::col_w $W ; set ::col_anchor 1.0 ; set ::col_caret 1.0 ; set ::col_active 1
ok "col: ctrl+key not typed"     [col_typed $W a 4] 0
col_clear
ok "col: clear ends selection"   $::col_active 0
ok "col: key ignored when off"   [col_typed $W a 0] 0
set ::col_on 0
col_begin $W 0 0
ok "col: begin inert when off"   $::col_active 0

# the Column Editing toggle is greyed out outside windows mode (the gesture only
# makes sense for the windows caret model; vi/emacs carry their own block notions)
set _savemode $::edit_mode
set ::edit_mode windows ; sync_column_edit_menu
ok "col: menu on in windows"     [.m.settings entrycget "Column Editing*" -state] normal
set ::edit_mode vi ; sync_column_edit_menu
ok "col: menu greyed off-windows" [.m.settings entrycget "Column Editing*" -state] disabled
set ::edit_mode $_savemode ; sync_column_edit_menu

# the Edit menu items exist and share the same procs
ok "menu: Cut entry"    [.m.edit entrycget "Cut" -command]        editor_cut
ok "menu: Select All"   [.m.edit entrycget "Select All" -command] editor_select_all

# --- switching to emacs: central wipe + the added motions ----------------------
set ::edit_mode emacs
apply_editmode
ok "emacs: attached"            $::editmode_active emacs
ok "emacs: windows chords gone" [bind RioMode <Control-x>] ""
ok "emacs: kill-line falls through" [bind RioMode <Control-k>] ""

clear_buf
.ed.t insert insert "one two three"
.ed.t mark set insert 1.7
ok "emacs: C-a fires"        [fire <Control-a>] ok
ok "emacs: C-a to linestart" [rio_real_t index insert] 1.0
ok "emacs: C-e fires"        [fire <Control-e>] ok
ok "emacs: C-e to lineend"   [rio_real_t index insert] 1.13
ok "emacs: C-b fires"        [fire <Control-b>] ok
ok "emacs: C-b back a char"  [rio_real_t index insert] 1.12

# --- THE Ctrl-V regression (the reported bug): emacs C-v scrolls, never pastes --
clear_buf
set lines "line"
for {set i 2} {$i <= 100} {incr i} { append lines "\nline $i" }
.ed.t insert insert $lines
.ed.t mark set insert 1.0
rio_real_t yview moveto 0
set_clip "CLIPBOARD JUNK"
set before [buf_text $::cur]
ok "emacs: C-v fires"           [fire <Control-v>] ok
ok "emacs: C-v never pastes"    [buf_text $::cur] $before
ok "emacs: C-v moved the view"  [expr {[lindex [rio_real_t yview] 0] > 0}] 1
ok "emacs: C-v moved the caret" [expr {[rio_real_t compare insert > 1.0]}] 1

# and in windows mode Ctrl-V is an explicit paste (what those users expect)
set ::edit_mode windows
apply_editmode
clear_buf
.ed.t insert insert "ab"
.ed.t mark set insert "1.0 lineend"
set_clip "XYZ"
fire <Control-v>
ok "win: C-v pastes"            [buf_text $::cur] "abXYZ"

# --- a split inherits the mode layer -------------------------------------------
set g2 [add_group]
ok "split: new widget tagged" [lindex [bindtags [gget $g2 path]] 1] RioMode
unsplit_editor

# --- prefs: the mode choice persists; an unknown name falls back ----------------
set ::edit_mode emacs
apply_editmode
set pf [open [prefs_path] r] ; set prefs [::read $pf] ; close $pf
ok "prefs: mode persisted"    [string match *\"editmode\":\"emacs\"* $prefs] 1
set ::edit_mode bogus
apply_editmode
ok "prefs: unknown falls back" $::edit_mode windows
ok "prefs: fallback attached"  $::editmode_active windows

# --- registry: later registration wins ------------------------------------------
set ::marker 0
rio::modes::register windows "Windows (patched)" \
	{apply {tag {incr ::marker ; rio::modes::win::attach $tag}}} rio::modes::win::detach
apply_editmode
ok "registry: later wins"      $::marker 1
ok "registry: label replaced"  [rio::modes::label windows] "Windows (patched)"
ok "registry: slot kept"       [lsearch -exact [rio::modes::names] windows] \
	[lsearch -exact [rio::modes::names] windows]

# --- loader: user drop-ins load; a broken one is skipped, not fatal -------------
file mkdir [modes_user_dir]
set f [open [file join [modes_user_dir] testmode.tcl] w]
puts $f {rio::modes::register testmode "Test Mode" {apply {tag {}}} {apply {tag {}}}}
close $f
set f [open [file join [modes_user_dir] broken.tcl] w]
puts $f {this is not tcl [}
close $f
set rc [catch {modes_load} err]
ok "loader: broken module survived" $rc 0
ok "loader: drop-in registered"     [rio::modes::exists testmode] 1
ok "loader: shipped restored"       [rio::modes::label windows] "Windows (Notepad-like)"
modes_menu_fill
set found 0
for {set i 0} {$i <= [.m.settings.editmode index end]} {incr i} {
	if {[.m.settings.editmode entrycget $i -label] eq "Test Mode"} { set found 1 }
}
ok "loader: drop-in in the menu"    $found 1
set ::edit_mode testmode
apply_editmode
ok "loader: drop-in activates"      $::editmode_active testmode
set ::edit_mode windows
apply_editmode

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

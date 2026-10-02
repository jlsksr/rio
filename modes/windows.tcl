# rio — the Windows editing mode (D38). The default.
#
# The text area behaves like Notepad:
#
#                  elsewhere         on a Mac (D136)
#   select all     Ctrl+A            Cmd+A
#   clipboard      Ctrl+C/X/V        Cmd+C/X/V
#   delete a word  Ctrl+Backspace,   Option+Backspace,
#                  Ctrl+Delete       Option+Delete
#   Tk's emacs     dead              kept: they are the Mac's own
#   keys (Ctrl+K)                    text keys
#
# Tk's Text class does the rest (arrows, Shift selection, Home/End); the
# app keymap (D23) does save, undo, find. The clipboard keys call the
# editor_* procs the Edit menu calls. Every edit goes through the group's
# proxy (%W), so through the core.

namespace eval rio::modes::win {}

# The keys that differ by platform, as {sequence script ...} for windowing
# system `ws`. Pure, so the Mac's table is tested on any host.
proc rio::modes::win::keys {ws} {
	set mac  [expr {$ws eq "aqua"}]
	set clip [expr {$mac ? "Command" : "Control"}]
	set word [expr {$mac ? "Option"  : "Control"}]
	set out [list \
		<$clip-a>         {editor_select_all %W ; break} \
		<$clip-c>         {editor_copy  %W ; break} \
		<$clip-x>         {editor_cut   %W ; break} \
		<$clip-v>         {editor_paste %W ; break} \
		<$word-BackSpace> {rio::modes::win::del_word_back %W ; break} \
		<$word-Delete>    {rio::modes::win::del_word_fwd  %W ; break}]
	# Tk's emacs keys are dead in this mode, except on a Mac. Ctrl+H and
	# Ctrl+O too: a user may have freed them in keys.json.
	set dead {<Insert>}
	if {!$mac} {
		lappend dead <Control-d> <Control-k> <Control-t> <Control-h> <Control-o> \
			<Control-space> <Control-Shift-space>
	}
	foreach seq $dead { lappend out $seq break }
	return $out
}

proc rio::modes::win::attach {tag} {
	foreach {seq script} [keys [tk windowingsystem]] { bind $tag $seq $script }
	bind $tag <Control-Insert> {editor_copy  %W ; break}
	bind $tag <Shift-Insert>   {editor_paste %W ; break}
	# Tab and Shift+Tab indent and dedent the selected lines, as one edit.
	# No selection: Tab inserts a tab, Shift+Tab dedents the caret's line.
	# A column selection: Tab types a tab down the column.
	# <ISO_Left_Tab> is Shift+Tab on X11.
	bind $tag <Tab>            {if {[col_here %W]} { col_edit insert \t } else { editor_indent %W } ; break}
	bind $tag <Shift-Tab>      {editor_dedent %W ; break}
	bind $tag <ISO_Left_Tab>   {editor_dedent %W ; break}

	# Column editing (D40), if ::col_on. Ctrl+Shift+drag makes a caret
	# over several lines; typing, Backspace and Delete then act on each.
	# Escape, a click or an arrow ends it. Not Alt+drag: Linux window
	# managers use that to move windows.
	bind $tag <Control-Shift-Button-1>        {if {$::col_on} { col_begin  %W %x %y ; break }}
	bind $tag <Control-Shift-B1-Motion>       {if {$::col_on} { col_motion %W %x %y ; break }}
	bind $tag <Control-Shift-ButtonRelease-1> {if {$::col_on} break}
	bind $tag <KeyPress>       {if {[col_typed %W %A %s]} break}
	bind $tag <BackSpace>      {if {[col_key %W delback]} break}
	bind $tag <Delete>         {if {[col_key %W delfwd]}  break}
	bind $tag <Escape>         {if {$::col_active} { col_clear ; break }}
	bind $tag <Button-1>       {col_clear}
	foreach _k {Left Right Up Down Home End Prior Next Return KP_Enter} { bind $tag <$_k> {col_clear} }
}

proc rio::modes::win::detach {tag} {
	# No state to drop.
}

# Delete back to the start of the previous word, or on to the start of
# the next.
proc rio::modes::win::del_word_back {w} {
	set from [tk::TextPrevPos $w insert tcl_startOfPreviousWord]
	if {[$w compare $from < insert]} { $w delete $from insert }
}

proc rio::modes::win::del_word_fwd {w} {
	set to [tk::TextNextPos $w insert tcl_startOfNextWord]
	# No next word: delete to the line end. Mid-line, stop at the line
	# end; at the line end, cross it and join the lines.
	if {$to eq "" || [$w compare $to <= insert]} { set to [$w index "insert lineend"] }
	if {[$w compare $to > "insert lineend"] && [$w compare insert < "insert lineend"]} {
		set to [$w index "insert lineend"]
	}
	if {[$w compare $to > insert]} { $w delete insert $to }
}

rio::modes::register windows "Windows (Notepad-like)" \
	rio::modes::win::attach rio::modes::win::detach

# rio — the Windows editing mode (AGENTS.md D38). The default.
#
# The text area behaves like Notepad / Notepad++: Ctrl+A selects all, Ctrl+C/X/V
# are the clipboard, Ctrl+Backspace/Delete eat a word, and Tk's emacs-flavoured
# extras (Ctrl+K kill-line, Ctrl+D delete-char, …) are deliberately dead so no
# readline behaviour leaks through. Tk's Text class already handles the rest of
# the Windows canon on its own — arrows, Ctrl+arrow word motion, Shift selection,
# Home/End, Prior/Next — and the app keymap (D23) supplies Ctrl+Z/Y/S/N/O/F/H/W.
#
# The clipboard actions call the GUI's shared editor_* procs (the same ones the
# Edit menu uses), so the menu and the keys can never drift apart. Every edit runs
# through the group's proxy (%W is the proxy path) and thus through the core.
#
# On a Mac (D136) the same mode speaks the Mac's spellings: Cmd+A/C/X/V, and
# Option+Backspace / Option+Delete for a word. Control is left alone there, because
# Ctrl+A, Ctrl+E, Ctrl+K, Ctrl+D, Ctrl+T, Ctrl+O and Ctrl+H are the system's own text
# keys, working in every Mac text field — and Tk's Text class already does them.

namespace eval rio::modes::win {}

# The platform's half of the mode, as {event-sequence script} pairs for windowing system
# `ws`. Pure, so the Mac's table is tested on any host.
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
	# Tk's built-in emacs leftovers, dead by design in this mode. (Ctrl+H and Ctrl+O
	# are normally taken by the app keymap first — replace / open — but a user who frees
	# those in keys.json still shouldn't fall into readline.) Not on a Mac: there the mode
	# takes no Control key at all, since those are the platform's own.
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
	# Tab / Shift+Tab indent and dedent the selected lines as one core edit,
	# preserving each line's existing whitespace (Tk's own <Tab> would delete the
	# selection). With no selection Tab inserts a plain tab; Shift+Tab dedents the
	# caret's line. <ISO_Left_Tab> is Shift+Tab on X11. (Ctrl+Tab / Ctrl+Shift+Tab
	# stay the app's tab-cycle keys — a different chord, untouched here.) When a
	# column selection is live, Tab types a tab down the whole column instead.
	bind $tag <Tab>            {if {[col_here %W]} { col_edit insert \t } else { editor_indent %W } ; break}
	bind $tag <Shift-Tab>      {editor_dedent %W ; break}
	bind $tag <ISO_Left_Tab>   {editor_dedent %W ; break}

	# Column / block editing (D40), pref-gated by ::col_on. Ctrl+Shift+drag makes a
	# vertical multi-line cursor; typing / Backspace / Delete then act at that column
	# on every spanned line (col_typed/col_key consume the event only while a column
	# selection is live, else normal editing flows through). Escape or an ordinary
	# click/arrow ends it. Alt+drag is Notepad++'s gesture but Linux WMs steal it to
	# move windows, so rio uses Ctrl+Shift+drag.
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
	# Stateless: nothing to tear down (the frontend clears the tag's bindings).
}

# Delete to the start of the previous word (Ctrl+Backspace) / onward to the start
# of the next word (Ctrl+Delete). The deletes go through the proxy -> core.
proc rio::modes::win::del_word_back {w} {
	set from [tk::TextPrevPos $w insert tcl_startOfPreviousWord]
	if {[$w compare $from < insert]} { $w delete $from insert }
}

proc rio::modes::win::del_word_fwd {w} {
	set to [tk::TextNextPos $w insert tcl_startOfNextWord]
	# No next word (end of text): eat to the line end. A next word on a LATER
	# line stops at the line end first (mid-line), but from the line end itself
	# it crosses over and joins — the VSCode/Notepad++ feel.
	if {$to eq "" || [$w compare $to <= insert]} { set to [$w index "insert lineend"] }
	if {[$w compare $to > "insert lineend"] && [$w compare insert < "insert lineend"]} {
		set to [$w index "insert lineend"]
	}
	if {[$w compare $to > insert]} { $w delete insert $to }
}

rio::modes::register windows "Windows (Notepad-like)" \
	rio::modes::win::attach rio::modes::win::detach

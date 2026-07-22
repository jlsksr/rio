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

namespace eval rio::modes::win {}

proc rio::modes::win::attach {tag} {
	bind $tag <Control-a>      {editor_select_all %W ; break}
	bind $tag <Control-c>      {editor_copy  %W ; break}
	bind $tag <Control-x>      {editor_cut   %W ; break}
	bind $tag <Control-v>      {editor_paste %W ; break}
	bind $tag <Control-Insert> {editor_copy  %W ; break}
	bind $tag <Shift-Insert>   {editor_paste %W ; break}
	bind $tag <Control-BackSpace> {rio::modes::win::del_word_back %W ; break}
	bind $tag <Control-Delete>    {rio::modes::win::del_word_fwd  %W ; break}
	# Tab / Shift+Tab indent and dedent the selected lines as one core edit,
	# preserving each line's existing whitespace (Tk's own <Tab> would delete the
	# selection). With no selection Tab inserts a plain tab; Shift+Tab dedents the
	# caret's line. <ISO_Left_Tab> is Shift+Tab on X11. (Ctrl+Tab / Ctrl+Shift+Tab
	# stay the app's tab-cycle keys — a different chord, untouched here.)
	bind $tag <Tab>            {editor_indent %W ; break}
	bind $tag <Shift-Tab>      {editor_dedent %W ; break}
	bind $tag <ISO_Left_Tab>   {editor_dedent %W ; break}
	# Tk's built-in emacs leftovers, dead by design in this mode. (Ctrl+H and
	# Ctrl+O are normally taken by the app keymap first — replace / open — but a
	# user who frees those in keys.json still shouldn't fall into readline.)
	foreach seq {<Control-d> <Control-k> <Control-t> <Control-h> <Control-o>
	             <Control-space> <Control-Shift-space> <Insert>} {
		bind $tag $seq break
	}
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

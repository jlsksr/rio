# rio — the Emacs editing mode (D38).
#
# MIT, like rio (D121). The notice is in this file because an installed
# extension has no LICENSE beside it (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# The readline feel. X11 Tk's Text class already does part of it (Ctrl+D,
# Ctrl+K, Ctrl+O, Ctrl+T, Ctrl+Space, the Meta word motions); those fall
# through. This mode adds what X11 Tk lacks:
#
#   Ctrl+A, Ctrl+E    line start, line end
#   Ctrl+B, Ctrl+P    one character back, one line up
#   Ctrl+V, Alt+V     page down, page up (X11 Tk binds Ctrl+V to paste)
#
# Ctrl+N/F/H/O are the app's (new, find, replace, open) and the app wins;
# free them in keys.json for the emacs meaning. No kill ring: Ctrl+K only
# deletes. Paste is the Edit menu, Shift+Insert or middle-click.

namespace eval rio::modes::emacs {}

proc rio::modes::emacs::attach {tag} {
	# Page scrolling, with Tk's own <Next>/<Prior> script: view, caret and
	# scrollbar move together.
	bind $tag <Control-v> {tk::TextSetCursor %W [tk::TextScrollPages %W  1] ; break}
	bind $tag <Alt-v>     {tk::TextSetCursor %W [tk::TextScrollPages %W -1] ; break}
	bind $tag <Meta-v>    {tk::TextSetCursor %W [tk::TextScrollPages %W -1] ; break}
	# The motions X11 Tk lacks.
	bind $tag <Control-a> {tk::TextSetCursor %W {insert display linestart} ; break}
	bind $tag <Control-e> {tk::TextSetCursor %W {insert display lineend}  ; break}
	bind $tag <Control-b> {tk::TextSetCursor %W insert-1displayindices    ; break}
	bind $tag <Control-p> {tk::TextSetCursor %W [tk::TextUpDownLine %W -1] ; break}
}

proc rio::modes::emacs::detach {tag} {
	# No state to drop.
}

rio::modes::register emacs "Emacs (readline)" \
	rio::modes::emacs::attach rio::modes::emacs::detach

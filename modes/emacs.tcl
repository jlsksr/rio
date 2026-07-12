# rio — the Emacs editing mode (AGENTS.md D38).
#
# The GNU-readline / basic-emacs feel. Tk's Text class already carries part of it
# on X11 (Ctrl+D delete-char, Ctrl+K kill-line, Ctrl+O open-line, Ctrl+T transpose,
# Ctrl+Space set-mark, Meta word motions) — those simply fall through this mode's
# tag untouched. What Tk's X11 build LACKS is added here: the line/char motions and
# real page scrolling on Ctrl+V (out of the box, X11 Tk maps Ctrl+V to <<Paste>> —
# the page-scroll binding is Mac-only — so Ctrl+V silently pasted; that was the
# "scrollbar moves but the view stays" bug this mode fixes).
#
# Honestly scoped: Ctrl+N/F/H/O belong to the app keymap (new / find / replace /
# open) and app chords always win — free them in keys.json if you want the emacs
# meaning. There is no kill ring in v1: Ctrl+K kills to the void (Tk behaviour);
# paste comes from the Edit menu, Shift+Insert, or middle-click.

namespace eval rio::modes::emacs {}

proc rio::modes::emacs::attach {tag} {
	# Page scrolling, exactly Tk's own <Next>/<Prior> script: view, caret and
	# scrollbar thumb move together.
	bind $tag <Control-v> {tk::TextSetCursor %W [tk::TextScrollPages %W  1] ; break}
	bind $tag <Alt-v>     {tk::TextSetCursor %W [tk::TextScrollPages %W -1] ; break}
	bind $tag <Meta-v>    {tk::TextSetCursor %W [tk::TextScrollPages %W -1] ; break}
	# The motions X11 Tk doesn't ship:
	bind $tag <Control-a> {tk::TextSetCursor %W {insert display linestart} ; break}
	bind $tag <Control-e> {tk::TextSetCursor %W {insert display lineend}  ; break}
	bind $tag <Control-b> {tk::TextSetCursor %W insert-1displayindices    ; break}
	bind $tag <Control-p> {tk::TextSetCursor %W [tk::TextUpDownLine %W -1] ; break}
}

proc rio::modes::emacs::detach {tag} {
	# Stateless: nothing to tear down (the frontend clears the tag's bindings).
}

rio::modes::register emacs "Emacs (readline)" \
	rio::modes::emacs::attach rio::modes::emacs::detach

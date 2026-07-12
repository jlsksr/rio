# rio — the editing-mode registry (AGENTS.md D38).
#
# An EDITING MODE decides what the keyboard does inside the text area: Windows-style
# (Notepad: Ctrl+A selects all, Ctrl+V pastes), Emacs-style (readline: Ctrl+A is
# start-of-line, Ctrl+V scrolls), or vi (modal). Like the cursor and selection (D22)
# it is pure frontend behaviour — the core never knows which mode is active; every
# edit still arrives as the same buffer.replace.
#
# A mode is SWAPPABLE the same way a syntax highlighter is (D32): it registers
# itself by name, and dropping a module into the user's modes dir shadows a shipped
# one. THIS registry is pure Tcl — no Tk — so it loads under tclsh for tests and a
# future TUI can reuse it. The mode MODULES, unlike syntax scanners, are frontend
# code: they install key bindings on a bind tag the GUI provides, so a TUI would
# pair this registry with its own mode modules.
#
# Contract. A mode registers a name, a human label, and two command prefixes:
#
#     rio::modes::register name label attach detach
#
#   attach <tag>   install the mode: `bind <tag> <chord> {script}` bindings and any
#                  per-editor state (cursor shape, marks). MUST be idempotent — the
#                  frontend re-runs it when a new editor widget appears (a split).
#   detach <tag>   tear down the mode's STATE (pending input, marks, cursor shape,
#                  status text). The frontend clears the tag's bindings itself, so
#                  detach never needs to unbind anything.
#
# The frontend guarantees the tag sits BELOW the app shortcuts and ABOVE Tk's Text
# class bindings: an app chord (D23 keymap — save, find, …) always wins over the
# mode; a mode binding ending in `break` wins over Tk's defaults; a mode binding
# that does not `break` falls through to them. A later registration for the same
# name WINS, which is what makes a user drop-in replace a shipped mode.

namespace eval rio::modes {
	variable modes {}   ;# name -> {label <text> attach <cmdprefix> detach <cmdprefix>}
	variable order {}   ;# first-registration order (drives the menu); re-register keeps the slot
}

# Register a mode. `name` is the machine name (persisted in prefs.json and shown
# nowhere); `label` is what the mode picker menu displays.
proc rio::modes::register {name label attach detach} {
	variable modes
	variable order
	dict set modes $name [dict create label $label attach $attach detach $detach]
	if {[lsearch -exact $order $name] < 0} { lappend order $name }
}

proc rio::modes::exists {name} {
	variable modes
	return [dict exists $modes $name]
}

# Registered mode names, in first-registration order (shipped modules load
# alphabetically, user drop-ins after — a drop-in replacing a shipped mode keeps
# its menu position).
proc rio::modes::names {} {
	variable order
	return $order
}

proc rio::modes::label {name} {
	variable modes
	return [dict get $modes $name label]
}

# Activate / deactivate a mode on a bind tag. One-line indirections so the frontend
# never invokes a module's commands by hand — the contract stays stated here.
proc rio::modes::attach {name tag} {
	variable modes
	{*}[dict get $modes $name attach] $tag
}

proc rio::modes::detach {name tag} {
	variable modes
	{*}[dict get $modes $name detach] $tag
}

# rio — the editing-mode registry (D38).
#
# An editing mode sets what keys do in the text area: Windows (Ctrl+A
# selects all), Emacs (Ctrl+A is line start), vi (modal). The core never
# knows the mode; every edit is still a buffer.replace.
#
# This registry is pure Tcl. A mode module is frontend code: it binds keys.
# A later registration for a name wins, so a file in the user's modes dir
# replaces a shipped mode.
#
#     rio::modes::register name label attach detach
#
#   attach <tag>   bind the mode's keys on <tag> and set up its state.
#                  Idempotent: it runs again for every new editor widget.
#   detach <tag>   drop the mode's state (pending input, marks, cursor
#                  shape). The frontend clears the bindings itself.
#
# Who gets a key first:
#
#   app shortcuts (D23)  ->  the mode's tag  ->  Tk's Text class
#
# A mode binding that ends in `break` stops Tk's default; one that does not
# falls through to it.
#
# mode-api (D123): the contract's version, declared in a mode's manifest,
# so the Extensions window can refuse a mode that needs a newer rio.
#
#   1  everything above, and: every edit goes through the group proxy (%W).
#
# No mode-api in a manifest means 1. The highest level this rio implements
# is ::mode_api_max in rio-gui/repos.tcl. Describe a new level here.

namespace eval rio::modes {
	variable modes {}   ;# name -> {label <text> attach <cmdprefix> detach <cmdprefix>}
	variable order {}   ;# first-registration order (drives the menu); re-register keeps the slot
}

# Register a mode. `name` is saved in prefs.json; `label` is what the menu
# shows.
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

# The mode names, in order of first registration: a replaced mode keeps
# its place in the menu.
proc rio::modes::names {} {
	variable order
	return $order
}

proc rio::modes::label {name} {
	variable modes
	return [dict get $modes $name label]
}

# Attach a mode to a bind tag, or detach it. The frontend calls these,
# never a module's own commands.
proc rio::modes::attach {name tag} {
	variable modes
	{*}[dict get $modes $name attach] $tag
}

proc rio::modes::detach {name tag} {
	variable modes
	{*}[dict get $modes $name detach] $tag
}

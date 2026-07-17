# rio-core — the theme.* op namespace (AGENTS.md D24, D11).
#
# Serves the theme role table as data so the GUI applier (and a future TUI) need
# no theme-loading logic of their own — the core owns the vocabulary, the default,
# and file parsing (rio::theme). The result is a nested object, the protocol's
# third non-flat shape; the wire encoder is told that shape (D25; see rio::wire).

# theme.get {?name?} -> {colors {<role> <value> ...} fonts {<NamedFont> {family size} ...}}
# No name (or "default") yields the built-in default; a name loads that theme
# file, merged over its base. A missing theme errors cleanly. A pure query.
proc rio::ops::theme_get {params} {
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	return [dict create result [rio::theme::load $name]]
}
rio::dispatch::register theme.get rio::ops::theme_get

# theme.list {} -> {themes [<name> ...]}
# Every loadable theme name — the built-in default plus the *.theme files on
# the search path, user dir shadowing shipped (D39). A pure query; feeds the
# GUI's dynamic View > Theme menu and the Extensions window.
proc rio::ops::theme_list {params} {
	return [dict create result [dict create themes [rio::theme::names]]]
}
rio::dispatch::register theme.list rio::ops::theme_list

# theme.put {name text} -> {}
# Install/overwrite a theme in the user themes dir (D39: the Extensions window
# installs themes through this — theme files are the CORE's to read, so they
# land on the core's disk, not the frontend's). The text is validated before
# anything is written; a bad name or unparseable text is bad_request.
proc rio::ops::theme_put {params} {
	foreach k {name text} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "theme.put requires $k"
		}
	}
	rio::theme::put [dict get $params name] [dict get $params text]
	return [dict create result {}]
}
rio::dispatch::register theme.put rio::ops::theme_put

# theme.delete {name} -> {}
# Remove a USER theme (D39 uninstall). Shipped examples and the built-in
# default are not removable — they are the installation, not user state.
proc rio::ops::theme_delete {params} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "theme.delete requires name"
	}
	rio::theme::delete [dict get $params name]
	return [dict create result {}]
}
rio::dispatch::register theme.delete rio::ops::theme_delete

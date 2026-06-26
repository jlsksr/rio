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

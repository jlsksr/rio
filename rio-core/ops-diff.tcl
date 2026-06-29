# rio-core — the diff.* op namespace (AGENTS.md D28).
#
# Thin handler over rio::diff. The compare/diff view (GUI now, TUI later) is a
# dumb view (D3): it sends two texts and renders the returned alignment, holding
# no diff logic of its own.

# diff.lines {a, b} -> {ops:[{tag,a,b}…]}
# The line-level alignment of text `a` against text `b` (see rio::diff::lines).
# A non-flat result (`ops` is an array), so the wire layer registers a shape
# encoder (D25; see rio::wire).
proc rio::ops::diff_lines {params} {
	foreach k {a b} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "diff.lines requires $k"
		}
	}
	return [dict create result \
		[dict create ops [rio::diff::lines [dict get $params a] [dict get $params b]]]]
}
rio::dispatch::register diff.lines rio::ops::diff_lines

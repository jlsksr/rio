# rio — the syntax-highlighting registry (AGENTS.md D32).
#
# Syntax highlighting is PRESENTATION, not document state — like the cursor and
# selection (D22) and the theme *applier* (D24), it is a frontend concern. So the
# tokenisers live here, in the frontend, as PURE Tcl modules: no Tk, no I/O, no
# protocol. Each highlighter turns text into a flat list of coloured spans; the
# frontend maps the span TYPES onto the theme's `syntax.*` colour roles and paints
# them (in the GUI, as text tags). Because a module is Tk-free it is portable — a
# future TUI reuses the identical files with its own applier.
#
# A highlighter is SWAPPABLE: it registers itself for a set of file extensions, so
# dropping a better `perl.tcl` into the user's syntax dir shadows the shipped one
# (same override pattern as themes, D24). No external packages — core Tcl only.
#
# Contract. A highlighter is a per-line SCANNER:
#
#     proc <ns>::scan {line state param} -> {spans nextstate nextparam}
#
# It scans ONE line of text that begins in tokeniser `state`/`param`, and returns:
#   spans      a flat {c0 c1 type c0 c1 type ...} of half-open COLUMN ranges within
#              the line (0-based columns — rio's shared position format, D12) each
#              tagged with one TOKEN TYPE from the vocabulary below;
#   nextstate  the opaque scan state ENTERING the next line (open comment, string
#              body, …) and its `nextparam` carry.
# Entering the FIRST line the state is the START pair (see `start`): a scanner must
# treat state "" as "start of document / plain text". Per-line is the natural unit
# for a state machine and it is what lets the frontend re-highlight INCREMENTALLY —
# it caches each line's entry state and, after an edit, re-scans from the changed
# line only until the state re-converges (see the GUI's hl_incremental).
#
# The whole-buffer `tokenize {scan text}` is DERIVED from the scanner (below), for
# tests and any consumer that just wants the lot in one call.
#
# Pure: no Tk here — tests headless under tclsh.

namespace eval rio::syntax {
	variable scanners {}     ;# ext (lowercased, no dot) -> scanner proc
	variable extlang  {}     ;# ext (lowercased, no dot) -> language display name
	variable langs {}        ;# lang name -> {exts <list> scanner <proc>} (introspection)
}

# The canonical TOKEN VOCABULARY. Highlighters emit only these type names; a theme
# maps each to a colour via a `syntax.<type>` role, and the GUI configures one text
# tag per type. Kept small and language-neutral so themes map a manageable set and
# highlighters share a vocabulary. A type a theme doesn't colour simply renders as
# ordinary text (the GUI falls the role back to editor.fg).
proc rio::syntax::tokens {} {
	return [list comment string number keyword tag attribute entity meta \
		operator function variable type constant]
}

# The START scan state — what a scanner is handed entering the first line. Kept in
# one place so neither the frontend nor the tests hardcode it.
proc rio::syntax::start {} {
	return [list "" ""]
}

# Register a highlighter: a language name (human-readable — shown in the GUI status
# bar), the file extensions it claims (bare, no dot — matched case-insensitively),
# and its per-line scanner proc. A later registration for the same extension WINS,
# which is what makes a user override replace a shipped highlighter (the frontend
# loads shipped modules first, user modules last).
proc rio::syntax::register {lang exts scan} {
	variable scanners
	variable extlang
	variable langs
	dict set langs $lang [dict create exts $exts scanner $scan]
	foreach e $exts {
		set e [string tolower $e]
		dict set scanners $e $scan
		dict set extlang  $e $lang
	}
}

# The scanner proc registered for a file path (by its extension), or "" when the
# file type has no highlighter (the caller then leaves the text un-highlighted).
proc rio::syntax::for_path {path} {
	variable scanners
	set ext [string tolower [string trimleft [file extension $path] .]]
	if {$ext ne "" && [dict exists $scanners $ext]} {
		return [dict get $scanners $ext]
	}
	return ""
}

# The language display NAME registered for a file path (by its extension), or ""
# when the file type has no highlighter — the frontend then shows a plain-text label.
# Parallels for_path: same "later registration wins" and case-insensitive matching.
proc rio::syntax::lang_for_path {path} {
	variable extlang
	set ext [string tolower [string trimleft [file extension $path] .]]
	if {$ext ne "" && [dict exists $extlang $ext]} {
		return [dict get $extlang $ext]
	}
	return ""
}

# Scan one line with a scanner. A one-line indirection so callers never invoke the
# scanner proc by hand — the contract stays stated in exactly one place.
proc rio::syntax::scan_line {scan line state param} {
	return [$scan $line $state $param]
}

# Whole-buffer convenience: drive the scanner over every line of `text` and flatten
# to {line.col line.col type ...} triples (1-based line, 0-based column). Derived
# from the per-line contract; used by the tests and any non-incremental consumer.
proc rio::syntax::tokenize {scan text} {
	set out {}
	lassign [start] state param
	set lineno 0
	foreach line [split $text "\n"] {
		incr lineno
		lassign [scan_line $scan $line $state $param] spans state param
		foreach {c0 c1 type} $spans {
			if {$c1 > $c0} { lappend out $lineno.$c0 $lineno.$c1 $type }
		}
	}
	return $out
}

# Is a valid token type? (For an applier that wants to ignore stray types.)
proc rio::syntax::is_token {type} {
	return [expr {[lsearch -exact [tokens] $type] >= 0}]
}

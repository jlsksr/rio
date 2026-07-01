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
# Contract. A tokeniser is  proc <ns>::tokenize {text} -> {i0 i1 type i0 i1 type ...}
# a flat list of triples: two `line.col` indices (1-based line, 0-based column —
# rio's shared position format, D12, and exactly what a Tk text tag consumes) and
# one TOKEN TYPE from the vocabulary below. Half-open [i0, i1). The tokeniser is a
# pure function of the whole buffer text; it must carry its own multi-line state
# (open comments, string bodies) so the result is context-correct.
#
# Pure: no Tk here — tests headless under tclsh.

namespace eval rio::syntax {
	variable tokenizers {}   ;# ext (lowercased, no dot) -> tokeniser proc
	variable langs {}        ;# lang id -> {exts <list> tokenizer <proc>} (introspection)
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

# Register a highlighter: a language id, the file extensions it claims (bare, no
# dot — matched case-insensitively), and its tokeniser proc. A later registration
# for the same extension WINS, which is what makes a user override replace a
# shipped highlighter (the frontend loads shipped modules first, user modules last).
proc rio::syntax::register {lang exts tokenizer} {
	variable tokenizers
	variable langs
	dict set langs $lang [dict create exts $exts tokenizer $tokenizer]
	foreach e $exts { dict set tokenizers [string tolower $e] $tokenizer }
}

# The tokeniser proc registered for a file path (by its extension), or "" when the
# file type has no highlighter (the caller then leaves the text un-highlighted).
proc rio::syntax::for_path {path} {
	variable tokenizers
	set ext [string tolower [string trimleft [file extension $path] .]]
	if {$ext ne "" && [dict exists $tokenizers $ext]} {
		return [dict get $tokenizers $ext]
	}
	return ""
}

# Run a tokeniser over text. A one-line indirection so callers never invoke the
# tokeniser proc by hand — the contract stays stated in exactly one place.
proc rio::syntax::tokenize {tokenizer text} {
	return [$tokenizer $text]
}

# Is a valid token type? (For an applier that wants to ignore stray types.)
proc rio::syntax::is_token {type} {
	return [expr {[lsearch -exact [tokens] $type] >= 0}]
}

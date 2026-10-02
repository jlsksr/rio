# rio — the syntax-highlighting registry (D32).
#
# Highlighting is presentation, so it lives in the frontend. A highlighter
# is pure Tcl (no Tk, no I/O, no packages): a terminal client can reuse it.
# It registers for file extensions; a later registration wins, so a file in
# the user's syntax dir replaces a shipped one.
#
# A highlighter is a scanner of one line:
#
#     proc <ns>::scan {line state param} -> {spans nextstate nextparam}
#
#   state, param   the state the line begins in; {"" ""} on the first line
#   spans          flat {c0 c1 type ...}: half-open, 0-based columns (D12),
#                  each with a type from `tokens`
#   nextstate,     the state the next line begins in (an open comment, a
#   nextparam      string body)
#
#     scan {x /* a} "" ""   ->   {2 6 comment} comment {}     (C, Go)
#
# Per line, so the frontend can cache each line's entry state and, after
# an edit, scan again only until the state matches the cache.

namespace eval rio::syntax {
	variable scanners {}     ;# ext (lowercased, no dot) -> scanner proc
	variable extlang  {}     ;# ext (lowercased, no dot) -> language display name
	variable filenames {}    ;# whole basename (lowercased) -> scanner proc (for extension-less files)
	variable filelang  {}    ;# whole basename (lowercased) -> language display name
	variable langs {}        ;# lang name -> {exts/files <list> scanner <proc>} (introspection)
}

# The token types. A highlighter emits only these; a theme colours each
# through its `syntax.<type>` role. A type without a role is plain text.
proc rio::syntax::tokens {} {
	return [list comment string number keyword tag attribute entity meta \
		operator function variable type constant]
}

# The {state param} a scanner gets for the first line.
proc rio::syntax::start {} {
	return [list "" ""]
}

# Register a highlighter: its display name, its extensions (no dot, any
# case) and its scanner. A later registration for an extension wins.
#   register Go {go} rio::syntax::go::scan
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

# Register a highlighter by file name, for files without an extension
# (Makefile, Dockerfile). Any case; a later registration wins.
proc rio::syntax::register_filename {lang names scan} {
	variable filenames
	variable filelang
	variable langs
	set entry [expr {[dict exists $langs $lang] ? [dict get $langs $lang] : {}}]
	dict set langs $lang [dict merge $entry [dict create files $names scanner $scan]]
	foreach nm $names {
		set nm [string tolower $nm]
		dict set filenames $nm $scan
		dict set filelang  $nm $lang
	}
}

# Look a path up in `files` (by name) and `exts` (by extension); "" if
# neither has it. In this order:
#   1. the file name          Makefile         -> Makefile
#   2. the extension          Makefile.tcl     -> Tcl
#   3. the name, less suffix  Dockerfile.prod  -> Dockerfile
proc rio::syntax::_resolve {path files exts} {
	set tail [string tolower [file tail $path]]
	if {[dict exists $files $tail]} { return [dict get $files $tail] }
	set ext [string tolower [string trimleft [file extension $path] .]]
	if {$ext ne "" && [dict exists $exts $ext]} { return [dict get $exts $ext] }
	set root [string tolower [file rootname [file tail $path]]]
	if {$root ne $tail && [dict exists $files $root]} { return [dict get $files $root] }
	return ""
}

# The scanner for a file path, or "".
proc rio::syntax::for_path {path} {
	variable scanners
	variable filenames
	return [_resolve $path $filenames $scanners]
}

# The language name for a file path, or "".
proc rio::syntax::lang_for_path {path} {
	variable extlang
	variable filelang
	return [_resolve $path $filelang $extlang]
}

# Every language name, sorted: the choices in View ▸ Language….
proc rio::syntax::names {} {
	variable langs
	return [lsort -dictionary [dict keys $langs]]
}

# The scanner for language name `lang`, or "".
proc rio::syntax::for_lang {lang} {
	variable langs
	if {![dict exists $langs $lang scanner]} { return "" }
	return [dict get $langs $lang scanner]
}

# Scan one line. Callers use this, never the scanner proc itself.
proc rio::syntax::scan_line {scan line state param} {
	return [$scan $line $state $param]
}

# Scan a whole text: {line.col line.col type ...}, lines from 1, columns
# from 0. For the tests.
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

# Is `type` a token type?
proc rio::syntax::is_token {type} {
	return [expr {[lsearch -exact [tokens] $type] >= 0}]
}

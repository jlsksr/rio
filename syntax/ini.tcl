# rio — an INI / properties syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O,
# no external packages — a per-line scanner (see rio::syntax for the contract). INI has no
# multi-line constructs, so it carries no state: every line stands alone.
#
# It colours: a `;` / `#` / `!` line comment (first non-blank char) as `comment`; a
# `[section]` header as `type`; the key of a `key = value` / `key : value` pair as
# `attribute`; and in the value region — `"…"` / `'…'` strings as `string`, whole-word
# booleans (`true`/`false`/`yes`/`no`/`on`/`off`, any case) as `constant`, numbers as
# `number`, and a trailing `;` / `#` comment (after whitespace) as `comment`. This spans
# the common dialects: classic INI (`;`), Java `.properties` (`#`/`!`, `=`/`:`), systemd
# unit / `.desktop` files, and `.editorconfig`.
#
# Scoped: an inline `;`/`#` only starts a comment when it follows whitespace, so a `#` or
# `;` inside a value (a URL fragment, a colour, a path) stays literal. Pure: no Tk here.

namespace eval rio::syntax::ini {}

set rio::syntax::ini::constants {true false yes no on off}

# scan ONE line (state is unused — INI is line-local). Returns {spans "" ""}.
proc rio::syntax::ini::scan {line state param} {
	set spans {}
	set n [string length $line]
	set lead [expr {$n - [string length [string trimleft $line { }]]}]

	# --- a whole-line comment: first non-blank char is ; # or ! --------------------
	set first [string index $line $lead]
	if {$lead < $n && ($first eq ";" || $first eq "#" || $first eq "!")} {
		return [list [list $lead $n comment] "" ""]
	}

	# --- a [section] header --------------------------------------------------------
	if {[regexp -indices {^[ \t]*(\[[^\]]*\])} $line whole sec]} {
		lappend spans [lindex $sec 0] [expr {[lindex $sec 1] + 1}] type
		return [list $spans "" ""]
	}

	# --- a key = value / key : value pair ------------------------------------------
	if {[regexp -indices {^[ \t]*([^\]\[=:;#! \t][^=:]*?)[ \t]*[=:]} $line whole key]} {
		lappend spans [lindex $key 0] [expr {[lindex $key 1] + 1}] attribute
		lassign [_tokvalue $line [expr {[lindex $whole 1] + 1}] $spans] spans
	}
	return [list $spans "" ""]
}

# Tokenise `line` from column `i` to end as an INI value region, appending to `spans`.
proc rio::syntax::ini::_tokvalue {line i spans} {
	variable constants
	set n [string length $line]
	while {$i < $n} {
		set ch   [string index $line $i]
		set sub  [string range $line $i end]
		set prev [string index $line [expr {$i - 1}]]
		if {($ch eq ";" || $ch eq "#") && ($i == 0 || [string is space $prev])} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\"" || $ch eq "'"} {
			set j [_strend $line $ch [expr {$i + 1}]]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {[string match {[0-9]} $ch] || (($ch eq "-" || $ch eq "+") && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
			set atbound [expr {$i == 0 || [string is space $prev] || $prev eq "=" || $prev eq ":"}]
			if {$atbound && [regexp -indices {^[-+]?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?} $sub m]} {
				set len [expr {[lindex $m 1] + 1}]
				lappend spans $i [expr {$i + $len}] number ; incr i $len
			} else { incr i }
		} elseif {[regexp -indices {^[[:alpha:]][[:alnum:]_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			set nx [string index $line [expr {$i + $len}]]
			if {[lsearch -exact -nocase $constants $word] >= 0 && ($nx eq "" || [string is space $nx])} {
				lappend spans $i [expr {$i + $len}] constant
			}
			incr i $len
		} else {
			incr i
		}
	}
	return [list $spans]
}

# The index of the closing quote `q` for a string beginning at column `i`; -1 if it does
# not close on this line. Honours `\` escapes.
proc rio::syntax::ini::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register INI {ini cfg conf properties desktop service editorconfig gitconfig} \
	rio::syntax::ini::scan

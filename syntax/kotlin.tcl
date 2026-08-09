# rio — a Kotlin syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `/* … */` block comment (which NESTS in Kotlin)
# and a `"""…"""` raw string each colour as one unit.
#
# It colours: `//` line and `/* … */` block comments as `comment` (nested `/* /* */ */`
# tracked by depth); `"…"` strings and `'c'` char literals (with `\` escapes) and
# multi-line `"""…"""` raw strings as `string`; numbers (with `0x`/`0b`, `_` separators,
# and `u`/`l`/`f` suffixes) as `number`; the declaration/control words as `keyword`;
# `null`/`true`/`false` as `constant`; `@Annotation`s as `meta`; a `fun` NAME and any
# called name (`name(`) as `function`; and a `class`/`object`/`interface` NAME plus any
# Capitalised identifier (a type by convention — Kotlin has no lower-case primitives) as
# `type`. Plain identifiers stay plain.
#
# Scoped: a `$name` / `${expr}` template hole inside a `"…"` is left coloured as part of
# the string (not separately lit) — the common case reads right. Pure: no Tk here.

namespace eval rio::syntax::kotlin {}

set rio::syntax::kotlin::keywords {
	package import class interface object fun val var typealias constructor init
	if else when while do for return break continue throw try catch finally
	in is as by where out
	public private protected internal
	abstract final open override sealed data enum annotation inner
	companion lateinit lazy const vararg noinline crossinline reified
	suspend inline infix operator external tailrec expect actual
	this super it field get set value param
}
set rio::syntax::kotlin::constants {null true false}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# comment (inside a block /* */; `param` is the nesting depth) | rawstr (inside a
# multi-line """…"""). The START state "" falls through to the code arm.
proc rio::syntax::kotlin::scan {line state param} {
	variable keywords
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	if {$state eq ""} { set state code }
	while {$i < $n} {
		switch -- $state {
			comment {
				lassign [_commentscan $line $i $param] end depth
				lappend spans $i $end comment ; set i $end
				if {$depth > 0} { set param $depth } else { set state code ; set param "" }
			}
			rawstr {
				set k [string first {"""} $line $i]
				if {$k < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$k + 3}] string ; set i [expr {$k + 3}] ; set state code }
			}
			default {  ;# code
				set ch [string index $line $i]
				set two [string range $line $i [expr {$i + 1}]]
				set sub [string range $line $i end]
				if {$two eq "//"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$two eq "/*"} {
					lassign [_commentscan $line $i 0] end depth
					lappend spans $i $end comment ; set i $end
					if {$depth > 0} { set state comment ; set param $depth }
				} elseif {[string range $line $i [expr {$i + 2}]] eq {"""}} {
					set pend ""
					set k [string first {"""} $line [expr {$i + 3}]]
					if {$k < 0} { lappend spans $i $n string ; set i $n ; set state rawstr } \
					else { lappend spans $i [expr {$k + 3}] string ; set i [expr {$k + 3}] }
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set pend ""
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "@" && [regexp -indices {^@[[:alpha:]_][[:alnum:]_.]*} $sub m]} {
					set pend ""
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] meta ; incr i $len
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)[uUlLfF]*} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] $pend ; set pend ""
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word eq "fun"} { set pend function }
						if {$word in {class interface object typealias}} { set pend type }
					} elseif {[string match {[A-Z]*} $word]} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {$after eq "("} {
						lappend spans $i [expr {$i + $len}] function
					}
					incr i $len
				} else {
					incr i
				}
			}
		}
	}
	return [list $spans $state $param]
}

# Scan a NESTED block comment starting at column `i` (already inside a comment at nesting
# `depth`, or `depth` 0 when `i` sits on the opening `/*`). Returns {end depth}: `end` is
# the column past the `*/` that closed the outermost comment (with returned depth 0), or
# the line length with the still-open depth to carry to the next line.
proc rio::syntax::kotlin::_commentscan {line i depth} {
	set n [string length $line]
	while {$i < $n} {
		set two [string range $line $i [expr {$i + 1}]]
		if {$two eq "/*"} { incr depth ; incr i 2 ; continue }
		if {$two eq "*/"} { incr depth -1 ; incr i 2 ; if {$depth <= 0} { return [list $i 0] } ; continue }
		incr i
	}
	return [list $n $depth]
}

# The end index (of the closing quote) of a "…"/'…' literal beginning at column `i`,
# honouring `\` escapes; -1 if it does not close on this line.
proc rio::syntax::kotlin::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Kotlin {kt kts} rio::syntax::kotlin::scan

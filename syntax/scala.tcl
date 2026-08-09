# rio — a Scala syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `/* … */` block comment (which NESTS in Scala)
# and a `"""…"""` multi-line string each colour as one unit.
#
# It colours: `//` line and `/* … */` block comments as `comment` (nested `/* /* */ */`
# tracked by depth); `"…"` and multi-line `"""…"""` strings (with `\` escapes) and `'c'`
# char literals as `string`; numbers (with `0x`, `_` separators, and `l`/`f`/`d`
# suffixes) as `number`; the declaration/control words (Scala 2 and 3) as `keyword`;
# `true`/`false`/`null` as `constant`; `@tailrec`-style annotations as `meta`; a `def`
# NAME and any called name (`name(`) as `function`; and a `class`/`object`/`trait` NAME
# plus any Capitalised identifier (a type by convention) as `type`. An interpolator
# prefix (`s"…"`, `f"…"`) reads naturally — the prefix is a plain identifier, the quoted
# part a string. Plain identifiers stay plain.
#
# Scoped: a `$name` / `${expr}` hole inside an interpolated string is left coloured as
# part of the string, and symbol literals (`'sym`, deprecated) are left plain — honest
# gaps. Pure: no Tk here — tests headless under tclsh.

namespace eval rio::syntax::scala {}

set rio::syntax::scala::keywords {
	abstract case catch class def do else extends final finally for forSome if
	implicit import lazy match new object override package private protected return
	sealed super this throw trait try type val var while with yield
	given using enum then end extension derives inline transparent opaque export
}
set rio::syntax::scala::constants {true false null}
set rio::syntax::scala::typeafter {class object trait type enum}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# comment (inside a block /* */; `param` is the nesting depth) | mlstr (inside a
# multi-line """…"""). The START state "" falls through to the code arm.
proc rio::syntax::scala::scan {line state param} {
	variable keywords
	variable constants
	variable typeafter
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
			mlstr {
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
					if {$k < 0} { lappend spans $i $n string ; set i $n ; set state mlstr } \
					else { lappend spans $i [expr {$k + 3}] string ; set i [expr {$k + 3}] }
				} elseif {$ch eq "\""} {
					set pend ""
					set j [_strend $line \" [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "'" && [regexp -indices {^'(?:\\.|[^'])'} $sub m]} {
					set pend ""
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] string ; incr i $len
				} elseif {$ch eq "@" && [regexp -indices {^@[[:alpha:]_][[:alnum:]_.]*} $sub m]} {
					set pend ""
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] meta ; incr i $len
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)[lLfFdD]*} $sub m
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
						if {$word eq "def"} { set pend function }
						if {[lsearch -exact $typeafter $word] >= 0} { set pend type }
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
# the column past the `*/` that closed the outermost comment (returned depth 0), or the
# line length with the still-open depth to carry to the next line.
proc rio::syntax::scala::_commentscan {line i depth} {
	set n [string length $line]
	while {$i < $n} {
		set two [string range $line $i [expr {$i + 1}]]
		if {$two eq "/*"} { incr depth ; incr i 2 ; continue }
		if {$two eq "*/"} { incr depth -1 ; incr i 2 ; if {$depth <= 0} { return [list $i 0] } ; continue }
		incr i
	}
	return [list $n $depth]
}

# The end index (of the closing quote) of a "…" literal beginning at column `i`, honouring
# `\` escapes; -1 if it does not close on this line.
proc rio::syntax::scala::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Scala {scala sc} rio::syntax::scala::scan

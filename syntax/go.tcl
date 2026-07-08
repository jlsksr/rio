# rio — a Go syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments and back-quoted raw strings colour
# as one unit.
#
# It colours: `//` and `/* … */` comments as `comment`; interpreted `"…"` strings and
# `'r'` rune literals as `string`, and back-quoted `` `…` `` raw strings (which span
# lines) as `string`; numbers (with `0x`/`0o`/`0b`, `_` separators, floats and the `i`
# imaginary suffix) as `number`; keywords as `keyword`; the predeclared type names
# (`int`, `string`, `bool`, …) as `type`; `true`/`false`/`nil`/`iota` as `constant`; a
# called/defined name (`name(`) as `function`; and a `type` NAME as `type`. Plain
# identifiers stay plain.

namespace eval rio::syntax::go {}

set rio::syntax::go::keywords {
	break case chan const continue default defer else fallthrough for func go goto if
	import interface map package range return select struct switch type var
}
set rio::syntax::go::types {
	bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64
	rune string uint uint8 uint16 uint32 uint64 uintptr any comparable
}
set rio::syntax::go::constants {true false nil iota}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */) | raw (a back-quoted `…` string spanning lines). The START
# state "" falls through to the code arm.
proc rio::syntax::go::scan {line state param} {
	variable keywords
	variable types
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	if {$state eq ""} { set state code }
	while {$i < $n} {
		switch -- $state {
			comment {
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state code }
			}
			raw {
				set k [string first "`" $line $i]
				if {$k < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$k + 1}] string ; set i [expr {$k + 1}] ; set state code }
			}
			default {  ;# code
				set ch [string index $line $i]
				set two [string range $line $i [expr {$i + 1}]]
				set sub [string range $line $i end]
				if {$two eq "//"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$two eq "/*"} {
					set k [string first "*/" $line [expr {$i + 2}]]
					if {$k < 0} { lappend spans $i $n comment ; set i $n ; set state comment } \
					else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] }
				} elseif {$ch eq "`"} {
					set pend ""
					set k [string first "`" $line [expr {$i + 1}]]
					if {$k < 0} { lappend spans $i $n string ; set i $n ; set state raw } \
					else { lappend spans $i [expr {$k + 1}] string ; set i [expr {$k + 1}] }
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set pend ""
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[oO][0-7_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)i?} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] type ; set pend ""
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $types $word] >= 0} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word eq "type"} { set pend type }
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

# The end index (of the closing quote) of a "…" / '…' literal beginning after column
# `i`, honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::go::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Go {go} rio::syntax::go::scan

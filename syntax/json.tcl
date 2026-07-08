# rio — a JSON syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `/* … */` comment colours as one unit.
#
# It colours: `"…"` strings as `string`, but an object KEY (a string whose next
# non-blank character is `:`) as `attribute`, so keys and values read apart; numbers
# (integer/float, optional sign and exponent, per RFC 8259) as `number`; `true`/`false`/
# `null` as `constant`. Strict JSON has no comments, but `.jsonc` and many real-world
# config files (tsconfig, VSCode settings) do, so `//` and `/* … */` are coloured as
# `comment` — an unambiguous, harmless extension. Structural punctuation stays plain.

namespace eval rio::syntax::json {}

set rio::syntax::json::constants {true false null}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */). The START state "" falls through to the code arm. JSON
# strings never span lines, so no string state carries across.
proc rio::syntax::json::scan {line state param} {
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	if {$state eq ""} { set state code }
	while {$i < $n} {
		switch -- $state {
			comment {
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state code }
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
				} elseif {$ch eq "\""} {
					set j [_strend $line [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n
					} else {
						# A key is a string whose next non-blank char is ':'.
						if {[regexp {^[ \t]*:} [string range $line [expr {$j + 1}] end]]} {
							lappend spans $i [expr {$j + 1}] attribute
						} else {
							lappend spans $i [expr {$j + 1}] string
						}
						set i [expr {$j + 1}]
					}
				} elseif {[string match {[0-9]} $ch] || ($ch eq "-" && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					regexp -indices {^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]]+} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					if {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
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

# The end index (of the closing quote) of a "…" string beginning after column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::json::_strend {line i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq "\""} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register JSON {json jsonc} rio::syntax::json::scan

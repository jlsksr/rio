# rio — a JavaScript syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O,
# no external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries its scan state across lines, so /* */ block comments and
# `template` literals colour correctly across line breaks.
#
# It colours: line (//) and block (/* */) comments, single/double-quoted strings and
# backtick template literals as `string`, numbers (decimal, hex/octal/binary, float,
# exponent, bigint) as `number`, reserved words as `keyword`, the literals
# true/false/null/undefined/NaN/Infinity as `constant`, and an identifier that is
# immediately called or defined (name followed by `(`) as `function`. Everything else
# — bare identifiers, operators, punctuation — is left plain. Regex literals are NOT
# recognised (indistinguishable from division without a full parser); a deliberate
# omission, noted so a `/…/ ` reads as plain text rather than being mis-strung.

namespace eval rio::syntax::js {}

# The reserved words → `keyword`.  Kept as a set for O(1) membership.
set rio::syntax::js::keywords {
	break case catch class const continue debugger default delete do else export
	extends finally for function if import in instanceof new return super switch this
	throw try typeof var void while with yield let static get set of as async await
}
# Literal values → `constant`.
set rio::syntax::js::constants {true false null undefined NaN Infinity}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: text | comment (block /* */) | tmpl (backtick template literal). The START
# state "" falls through to the text arm, so line 1 needs no special-casing. A line
# (//) comment and quoted strings are consumed within the line, so they carry no
# state; only block comments and template literals span lines.
proc rio::syntax::js::scan {line state param} {
	variable keywords
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	while {$i < $n} {
		switch -- $state {
			comment {
				set j [string first "*/" $line $i]
				if {$j < 0} {
					lappend spans $i $n comment ; set i $n
				} else {
					lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}] ; set state text
				}
			}
			tmpl {
				set j [_strend $line "`" $i]
				if {$j < 0} {
					lappend spans $i $n string ; set i $n
				} else {
					lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state text
				}
			}
			default {  ;# text
				set ch [string index $line $i]
				set ch2 [string range $line $i [expr {$i + 1}]]
				if {$ch2 eq "//"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$ch2 eq "/*"} {
					set j [string first "*/" $line [expr {$i + 2}]]
					if {$j < 0} {
						lappend spans $i $n comment ; set i $n ; set state comment
					} else {
						lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}]
					}
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n   ;# unterminated: to EOL, no carry
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {$ch eq "`"} {
					set j [_strend $line "`" [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n ; set state tmpl
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					regexp -indices {^(?:0[xX][[:xdigit:]]+|0[bB][01]+|0[oO][0-7]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)n?} \
						[string range $line $i end] m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_$][[:alnum:]_$]*} [string range $line $i end] m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					if {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[string index $line [expr {$i + $len}]] eq "("} {
						lappend spans $i [expr {$i + $len}] function
					}
					incr i $len
				} else {
					incr i   ;# operators, punctuation, whitespace: plain
				}
			}
		}
	}
	return [list $spans $state $param]
}

# The end index (of the closing delimiter) of a string beginning at column `i`,
# honouring backslash escapes; -1 if it does not close on this line. Shared by the
# quoted-string and template-literal scans (`q` is the closing char).
proc rio::syntax::js::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register JavaScript {js mjs cjs jsx} rio::syntax::js::scan

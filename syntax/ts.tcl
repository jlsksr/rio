# rio — a TypeScript syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). A superset of the JavaScript scanner: it carries scan state across lines, so
# `/* … */` block comments and backtick `template` literals colour across line breaks.
#
# Over JavaScript it adds: the type-system keywords (`interface`/`type`/`enum`/`namespace`/
# `declare`/`readonly`/`keyof`/`infer`/`is`/`satisfies`/access modifiers) as `keyword`; the
# built-in type names (`string`/`number`/`boolean`/`any`/`unknown`/`never`/…) and any
# Capitalised identifier (a class / type by convention) as `type`; and `@Component`-style
# decorators as `meta`. Also colours: `//` and `/* … */` comments; `'…'`/`"…"`/`` `…` ``
# strings; numbers (hex/oct/bin, `_` separators, bigint `n`); `true`/`false`/`null`/
# `undefined`/`NaN`/`Infinity` as `constant`; and a called/defined name (`name(`) as
# `function`. Regex literals are NOT recognised (indistinguishable from division without a
# full parser) — a deliberate gap, noted so a `/…/` reads plain. Pure: no Tk here.

namespace eval rio::syntax::ts {}

set rio::syntax::ts::keywords {
	break case catch class const continue debugger default delete do else export
	extends finally for function if import in instanceof new return super switch this
	throw try typeof var void while with yield let static get set of as async await
	interface type enum namespace module declare implements abstract readonly public
	private protected keyof infer is asserts satisfies override accessor using
}
set rio::syntax::ts::types {
	string number boolean any unknown never object symbol bigint
}
set rio::syntax::ts::constants {true false null undefined NaN Infinity}
set rio::syntax::ts::typeafter {class interface type enum}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: text |
# comment (block /* */) | tmpl (backtick template literal). The START state "" falls
# through to the text arm.
proc rio::syntax::ts::scan {line state param} {
	variable keywords
	variable types
	variable constants
	variable typeafter
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	while {$i < $n} {
		switch -- $state {
			comment {
				set j [string first "*/" $line $i]
				if {$j < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}] ; set state text }
			}
			tmpl {
				set j [_strend $line "`" $i]
				if {$j < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state text }
			}
			default {  ;# text
				set ch [string index $line $i]
				set ch2 [string range $line $i [expr {$i + 1}]]
				set sub [string range $line $i end]
				if {$ch2 eq "//"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$ch2 eq "/*"} {
					set j [string first "*/" $line [expr {$i + 2}]]
					if {$j < 0} { lappend spans $i $n comment ; set i $n ; set state comment } \
					else { lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}] }
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set pend ""
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "`"} {
					set pend ""
					set j [_strend $line "`" [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n ; set state tmpl } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "@" && [regexp -indices {^@[[:alpha:]_$][[:alnum:]_$.]*} $sub m]} {
					set pend ""
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] meta ; incr i $len
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|0[oO][0-7_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)n?} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_$][[:alnum:]_$]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] $pend ; set pend ""
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {[lsearch -exact $typeafter $word] >= 0} { set pend type }
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $types $word] >= 0} {
						lappend spans $i [expr {$i + $len}] type
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

# The end index (of the closing delimiter) of a string beginning at column `i`, honouring
# backslash escapes; -1 if it does not close on this line. Shared by the quoted-string and
# template-literal scans (`q` is the closing char).
proc rio::syntax::ts::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register TypeScript {ts tsx mts cts} rio::syntax::ts::scan

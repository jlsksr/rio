# rio — a Java syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so a `/* … */` (or `/** … */` Javadoc) block comment
# colours as one unit.
#
# It colours: `//` line and `/* … */` block comments as `comment`; `"…"` strings and
# `'c'` char literals (with `\` escapes) as `string`; numbers (with `0x`/`0b`, `_`
# separators, and `f`/`d`/`l` suffixes) as `number`; control/modifier words as `keyword`
# and the primitive type names (`int`/`boolean`/`void`/…) as `type`; `true`/`false`/`null`
# as `constant`; `@Override`-style annotations as `meta`; a called/defined name (`name(`)
# as `function`; a `class`/`interface`/`enum`/`new` NAME and any Capitalised identifier
# (class / type by convention) as `type`. Plain identifiers stay plain.
#
# Deliberately NOT tracked (an honest gap, so nothing is mis-coloured): text blocks
# (`"""…"""`) — a regular string never spans a line in Java, so an unterminated `"…"` is
# just coloured to end-of-line. Pure: no Tk here — tests headless under tclsh.

namespace eval rio::syntax::java {}

set rio::syntax::java::keywords {
	abstract assert break case catch class const continue default do else enum
	extends final finally for goto if implements import instanceof interface
	native new package private protected public return static strictfp super
	switch synchronized this throw throws transient try volatile while
	yield var record sealed permits requires exports opens uses provides module
}
set rio::syntax::java::types {
	boolean byte char short int long float double void
}
set rio::syntax::java::constants {true false null}
# After these, the next identifier names a type.
set rio::syntax::java::typeafter {class interface enum new record}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# comment (block /* */). The START state "" falls through to the code arm.
proc rio::syntax::java::scan {line state param} {
	variable keywords
	variable types
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
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)[fFdDlL]*} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_$][[:alnum:]_$]*} $sub m]} {
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

# The end index (of the closing quote) of a "…"/'…' literal beginning at column `i`,
# honouring `\` escapes; -1 if it does not close on this line.
proc rio::syntax::java::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Java {java} rio::syntax::java::scan

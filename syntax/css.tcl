# rio — a CSS syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries its scan state across lines, so multi-line /* */ comments
# and quoted strings colour correctly.
#
# It colours: comments (/* */), at-rules (@media, @import, …) as `keyword`, quoted
# strings, numbers (with units) and hex colours (#abc, #aabbcc) as `number`, the
# `!important` flag as `keyword`, property names inside a declaration block as
# `attribute`, and function names (rgb(, url(, calc(, …) as `function`. Selector
# text and value keywords are left plain — deliberately, to avoid mis-colouring the
# many bare identifiers CSS allows. The block structure is tracked so a property
# name is only coloured where a property actually goes (inside `{ … }`), and nested
# at-rule blocks (@media { .x { … } }) resolve correctly.

namespace eval rio::syntax::css {}

# Which at-rules open a nested RULE-LIST (more selectors) rather than a declaration
# block — so `@media screen { .x { … } }` colours the inner `.x { … }` as a rule,
# not as declarations. Everything else's `{` opens a declaration block.
set rio::syntax::css::nesting {media supports document layer container scope \
	keyframes -moz-document -webkit-keyframes -moz-keyframes -o-keyframes}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract).
# States: sel (selector / rule-list context) | decl (inside a declaration block) |
# comment | str. The START state "" falls through to the sel arm, so line 1 needs no
# special-casing. `param` carries: st (the stack of enclosing context states, for
# nesting), at (in sel: 1 while a nesting at-rule is pending its `{`), val (in decl:
# 1 once past the `:`, i.e. in the value), and back/bp/quote (in comment/str: the
# state+param to resume, and the string's quote char).
proc rio::syntax::css::scan {line state param} {
	variable nesting
	if {$state eq ""} { set state sel }
	if {![dict exists $param st]}  { dict set param st {} }
	if {![dict exists $param at]}  { dict set param at 0 }
	if {![dict exists $param val]} { dict set param val 0 }
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
					lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}]
					set state [dict get $param back] ; set param [dict get $param bp]
				}
			}
			str {
				set q [dict get $param quote]
				set j [_strend $line $q $i]
				if {$j < 0} {
					lappend spans $i $n string ; set i $n
				} else {
					lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					set state [dict get $param back] ; set param [dict get $param bp]
				}
			}
			decl {
				set ch [string index $line $i]
				if {$ch eq "/" && [string index $line [expr {$i + 1}]] eq "*"} {
					set param [dict create back decl bp $param] ; set state comment
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n
						set state str ; set param [dict create back decl bp $param quote $ch]
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {$ch eq "\}"} {
					lassign [_pop $param] state param ; incr i
				} elseif {$ch eq "\{"} {
					set param [_push $param decl] ; set state decl ; incr i
				} elseif {$ch eq ":"} {
					dict set param val 1 ; incr i
				} elseif {$ch eq ";"} {
					dict set param val 0 ; incr i
				} elseif {$ch eq "#" && [dict get $param val]} {
					if {[regexp -indices {^#[[:xdigit:]]+} [string range $line $i end] m]} {
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $i [expr {$i + $len}] number ; incr i $len
					} else { incr i }
				} elseif {$ch eq "!"} {
					if {[regexp -indices {^![[:alpha:]-]+} [string range $line $i end] m]} {
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $i [expr {$i + $len}] keyword ; incr i $len
					} else { incr i }
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					incr i [_number $line $i spans]
				} elseif {[regexp -indices {^-{0,2}[[:alpha:]][[:alnum:]_-]*} [string range $line $i end] m]} {
					set len [expr {[lindex $m 1] + 1}]
					if {[string index $line [expr {$i + $len}]] eq "("} {
						lappend spans $i [expr {$i + $len}] function
					} elseif {![dict get $param val]} {
						lappend spans $i [expr {$i + $len}] attribute
					}
					incr i $len
				} else {
					incr i   ;# whitespace, punctuation, a plain value keyword
				}
			}
			default {  ;# sel — selector / rule-list context
				set ch [string index $line $i]
				if {$ch eq "/" && [string index $line [expr {$i + 1}]] eq "*"} {
					set param [dict create back sel bp $param] ; set state comment
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n
						set state str ; set param [dict create back sel bp $param quote $ch]
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {$ch eq "@"} {
					if {[regexp -indices {^@[[:alpha:]-]+} [string range $line $i end] m]} {
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $i [expr {$i + $len}] keyword
						set name [string tolower [string range $line [expr {$i + 1}] [expr {$i + $len - 1}]]]
						dict set param at [expr {[lsearch -exact $nesting $name] >= 0}]
						incr i $len
					} else { incr i }
				} elseif {$ch eq "\{"} {
					set next [expr {[dict get $param at] ? "sel" : "decl"}]
					set param [_push $param sel] ; set state $next ; incr i
				} elseif {$ch eq "\}"} {
					lassign [_pop $param] state param ; incr i
				} elseif {$ch eq ";"} {
					dict set param at 0 ; incr i
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					incr i [_number $line $i spans]
				} else {
					incr i   ;# selector text (elements, .class, #id, :pseudo) left plain
				}
			}
		}
	}
	return [list $spans $state $param]
}

# Push the current context state `cur` onto the stack, resetting the per-context
# flags for the block we're entering; the caller sets `state` to the inner context.
proc rio::syntax::css::_push {param cur} {
	set st [dict get $param st]
	lappend st $cur
	return [dict create st $st at 0 val 0]
}

# Pop back to the enclosing context; returns {state param}. At top level, back to sel.
proc rio::syntax::css::_pop {param} {
	set st [dict get $param st]
	if {[llength $st] == 0} {
		return [list sel [dict create st {} at 0 val 0]]
	}
	set back [lindex $st end]
	return [list $back [dict create st [lrange $st 0 end-1] at 0 val 0]]
}

# Scan a number (integer/float, optional leading '-', trailing unit or %) at column
# `i`, appending its span to the list named by `spansvar`; returns the length consumed.
proc rio::syntax::css::_number {line i spansvar} {
	upvar 1 $spansvar spans
	regexp -indices {^-?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[[:alpha:]]+|%)?} \
		[string range $line $i end] m
	set len [expr {[lindex $m 1] + 1}]
	lappend spans $i [expr {$i + $len}] number
	return $len
}

# The end index (of the closing quote) of a string beginning after column `i`,
# honouring backslash escapes; -1 if the quote does not close on this line.
proc rio::syntax::css::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register CSS {css} rio::syntax::css::scan

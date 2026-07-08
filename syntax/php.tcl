# rio — a PHP syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments, multi-line strings, and the
# HTML-vs-PHP boundary all colour correctly.
#
# PHP is embedded: text outside `<?php … ?>` is HTML/plain and left un-highlighted;
# the `<?php` / `<?=` / `?>` markers are `meta`; inside, full PHP colours. It colours:
# `//` and `#` line comments and `/* … */` block comments as `comment`; `'…'` and
# `"…"` strings (multi-line) as `string`; `$var` (and `$this`, `$$v`) as `variable`;
# numbers; keywords as `keyword`; `true`/`false`/`null` as `constant`; a called/defined
# name (`name(`) and a `function` NAME as `function`; and a class-ish name (after
# `new`/`class`/`extends`/…, or a `\Ns\Class`) as `type`. Honest gap (nothing
# mis-coloured): here/nowdoc (`<<<EOT`) is not tracked — its marker line reads plain.

namespace eval rio::syntax::php {}

set rio::syntax::php::keywords {
	if else elseif endif while endwhile for endfor foreach endforeach do switch
	endswitch case default break continue return goto declare
	function fn class interface trait enum extends implements new clone instanceof
	public private protected static abstract final const var readonly
	namespace use as global echo print require require_once include include_once
	try catch finally throw match yield and or xor not
	public private protected abstract final list array isset unset empty exit die
}
set rio::syntax::php::constants {true false null TRUE FALSE NULL}
# After these, the next identifier names a class/type (or, for `function`, a function).
set rio::syntax::php::typeafter {new class interface trait enum extends implements instanceof}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a
# flat {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States:
# html (outside PHP — plain) | php | comment (block /* */) | str (quote char). The
# START state "" is treated as html, so a mixed .php template works from line 1.
proc rio::syntax::php::scan {line state param} {
	variable keywords
	variable constants
	variable typeafter
	set spans {}
	set n [string length $line]
	set i 0
	if {$state eq ""} { set state html }
	set pend ""
	while {$i < $n} {
		switch -- $state {
			html {
				set j [string first "<?" $line $i]
				if {$j < 0} { set i $n ; continue }
				if {[regexp -indices {^<\?php|^<\?=|^<\?} [string range $line $j end] m]} {
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $j [expr {$j + $len}] meta ; set i [expr {$j + $len}]
					set state php
				} else { set i [expr {$j + 2}] }
			}
			comment {
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state php }
			}
			str {
				set q [dict get $param q]
				set s0 $i ; set done 0
				while {$i < $n} {
					set c [string index $line $i]
					if {$q eq "\"" && $c eq "\\"} { incr i 2 ; continue }
					if {$q eq "'" && $c eq "\\" && [string index $line [expr {$i + 1}]] eq "'"} { incr i 2 ; continue }
					if {$c eq $q} { incr i ; set done 1 ; break }
					incr i
				}
				set e [expr {$i > $n ? $n : $i}]
				if {$e > $s0} { lappend spans $s0 $e string }
				if {$done} { set state php }
			}
			default {  ;# php
				set ch [string index $line $i]
				set two [string range $line $i [expr {$i + 1}]]
				set sub [string range $line $i end]
				if {$two eq "?>"} {
					lappend spans $i [expr {$i + 2}] meta ; incr i 2 ; set state html ; set pend ""
				} elseif {$two eq "//" || $ch eq "#"} {
					lappend spans $i $n comment ; set i $n
				} elseif {$two eq "/*"} {
					set k [string first "*/" $line [expr {$i + 2}]]
					if {$k < 0} { lappend spans $i $n comment ; set i $n ; set state comment } \
					else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] }
				} elseif {$ch eq "\"" || $ch eq "'"} {
					set pend ""
					set j [_strend $line $ch [expr {$i + 1}]]
					if {$j < 0} {
						lappend spans $i $n string ; set i $n ; set state str ; set param [dict create q $ch]
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {$ch eq "\$"} {
					set pend ""
					if {[regexp -indices {^\$+[[:alpha:]_][[:alnum:]_]*} $sub m]} {
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $i [expr {$i + $len}] variable ; incr i $len
					} else { incr i }
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|0[oO][0-7_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^\\?[[:alpha:]_][[:alnum:]_]*(?:\\[[:alpha:]_][[:alnum:]_]*)*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] $pend ; set pend ""
					} elseif {[string first "\\" $word] >= 0} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word eq "function" || $word eq "fn"} { set pend function } \
						elseif {[lsearch -exact $typeafter $word] >= 0} { set pend type }
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

# The end index (of the closing quote) of a string beginning after column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::php::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register PHP {php php3 php4 php5 phtml phps} rio::syntax::php::scan

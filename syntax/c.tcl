# rio — a C syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments colour as one unit.
#
# It colours: `//` and `/* … */` comments as `comment`; preprocessor directives
# (`#include`, `#define`, …) as `meta`, with a `<header.h>` on an include line as
# `string`; `"…"` strings and `'c'` char literals as `string`; numbers (with `0x`/`0b`
# and int/float suffixes) as `number`; control/storage keywords as `keyword`; the
# built-in type names (and any `…_t`) as `type`; `NULL`/`true`/`false` as `constant`;
# a called/defined name (`name(`) as `function`; and a `struct`/`union`/`enum` tag name
# as `type`. Plain identifiers stay plain.

namespace eval rio::syntax::c {}

set rio::syntax::c::keywords {
	if else for while do switch case default break continue return goto
	typedef static extern const volatile register auto inline restrict _Noreturn
	struct union enum signed unsigned sizeof _Alignas _Alignof _Atomic _Static_assert
	_Thread_local _Generic asm
}
set rio::syntax::c::types {
	void char short int long float double bool _Bool _Complex _Imaginary
	size_t ssize_t ptrdiff_t wchar_t intptr_t uintptr_t FILE va_list
}
set rio::syntax::c::constants {NULL true false}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */) | str (string/char literal; `param` holds the quote). The
# START state "" falls through to the code arm.
proc rio::syntax::c::scan {line state param} {
	variable keywords
	variable types
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	# Preprocessor: a line whose first non-blank char is `#` is a directive.
	if {($state eq "" || $state eq "code") && [regexp -indices {^[ \t]*#[ \t]*[[:alpha:]_]*} $line m]} {
		set e [expr {[lindex $m 1] + 1}]
		lappend spans [lindex $m 0] $e meta
		set i $e
		if {[regexp {^[ \t]*#[ \t]*include} $line] && [regexp -indices {<[^>]*>} $line inc]} {
			lappend spans [lindex $inc 0] [expr {[lindex $inc 1] + 1}] string
		}
	}
	if {$state eq ""} { set state code }
	while {$i < $n} {
		switch -- $state {
			comment {
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state code }
			}
			str {
				set q [dict get $param q]
				set s0 $i ; set done 0
				while {$i < $n} {
					set c [string index $line $i]
					if {$c eq "\\"} { incr i 2 ; continue }
					if {$c eq $q} { incr i ; set done 1 ; break }
					incr i
				}
				set e [expr {$i > $n ? $n : $i}]
				if {$e > $s0} { lappend spans $s0 $e string }
				if {$done} { set state code }
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
					if {$j < 0} {
						lappend spans $i $n string ; set i $n ; set state str ; set param [dict create q $ch]
					} else {
						lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}]
					}
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]]+|0[bB][01]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)[uUlLfF]*} $sub m
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
					} elseif {[lsearch -exact $types $word] >= 0 || [string match {*_t} $word]} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {$word in {struct union enum}} { set pend type }
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
proc rio::syntax::c::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register C {c h} rio::syntax::c::scan

# rio — a C# syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments and verbatim (@"…") strings colour
# as one unit.
#
# It colours: `//`/`///` line and `/* … */` block comments as `comment`; strings as
# `string` in all their C# forms — regular `"…"` (with `\` escapes), verbatim `@"…"`
# (multi-line, `""` escapes the quote), interpolated `$"…"`, and interpolated-verbatim
# `$@"…"` — plus `'c'` char literals; numbers (with `0x`/`0b`, `_` separators, and
# `f`/`d`/`m`/`u`/`l` suffixes); the C-style type/keyword split — control/modifier words
# as `keyword`, built-in type names (`int`/`string`/`bool`/…) as `type`; `true`/`false`/
# `null` as `constant`; a called/defined name (`name(`) as `function`; and a
# `class`/`struct`/`interface`/`enum`/`new` NAME as `type`. Interpolation holes inside a
# `$"…"` are not separately coloured, and raw string literals (`"""…"""`) are not tracked
# — honest gaps, noted so nothing is mis-coloured.

namespace eval rio::syntax::csharp {}

set rio::syntax::csharp::keywords {
	abstract as base break case catch checked class const continue default delegate do
	else enum event explicit extern finally fixed for foreach goto if implicit in
	interface internal is lock namespace new operator out override params private
	protected public readonly ref return sealed sizeof stackalloc static struct switch
	this throw try typeof unchecked unsafe using virtual volatile while
	async await yield get set add remove value var dynamic nameof when where record init
	partial global select from join into orderby group by let notnull unmanaged with
}
set rio::syntax::csharp::types {
	bool byte sbyte char decimal double float int uint long ulong short ushort
	object string void nint nuint
}
set rio::syntax::csharp::constants {true false null}
# After these, the next identifier names a type.
set rio::syntax::csharp::typeafter {class struct interface enum new delegate record}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */) | vstr (inside a multi-line verbatim @"…" string). The START
# state "" falls through to the code arm.
proc rio::syntax::csharp::scan {line state param} {
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
				set k [string first "*/" $line $i]
				if {$k < 0} { lappend spans $i $n comment ; set i $n } \
				else { lappend spans $i [expr {$k + 2}] comment ; set i [expr {$k + 2}] ; set state code }
			}
			vstr {
				set close [_vend $line $i]
				if {$close < 0} {
					if {$n > $i} { lappend spans $i $n string } ; set i $n
				} else {
					lappend spans $i [expr {$close + 1}] string ; set i [expr {$close + 1}] ; set state code
				}
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
				} elseif {$ch eq "'"} {
					set pend ""
					set j [_strend $line ' [expr {$i + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "\"" || (($ch eq "@" || $ch eq "\$") && [regexp {^(?:@\$|\$@|@|\$)"} $sub])} {
					set pend ""
					incr i [_string $line $i spans state]
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?)[fFdDmMuUlL]*} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^@?[[:alpha:]_][[:alnum:]_]*} $sub m]} {
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

# Scan a string literal beginning at column `i` (a `"` with an optional `@`/`$`/`$@`/
# `@$` prefix). Appends the `string` span and, for an unterminated verbatim string, sets
# the caller's `state` to `vstr`. Returns the length consumed on THIS line.
proc rio::syntax::csharp::_string {line i spansvar statevar} {
	upvar 1 $spansvar spans $statevar state
	set n [string length $line]
	regexp {^(?:@\$|\$@|@|\$)?} [string range $line $i end] pfx
	set verbatim [string match *@* $pfx]
	set q0 [expr {$i + [string length $pfx]}]   ;# column of the opening quote
	if {$verbatim} {
		set close [_vend $line [expr {$q0 + 1}]]
		if {$close < 0} { lappend spans $i $n string ; set state vstr ; return [expr {$n - $i}] }
	} else {
		set close [_strend $line \" [expr {$q0 + 1}]]
		if {$close < 0} { lappend spans $i $n string ; return [expr {$n - $i}] }
	}
	lappend spans $i [expr {$close + 1}] string
	return [expr {$close + 1 - $i}]
}

# The end index of a regular `"…"`/`'…'` literal beginning at column `i`, honouring `\`
# escapes; -1 if it does not close on this line.
proc rio::syntax::csharp::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

# The end index of a verbatim @"…" string body beginning at column `i`: a lone `"`
# closes it, but a doubled `""` is an escaped quote; -1 if it does not close this line.
proc rio::syntax::csharp::_vend {line i} {
	set n [string length $line]
	while {$i < $n} {
		if {[string index $line $i] eq "\""} {
			if {[string index $line [expr {$i + 1}]] eq "\""} { incr i 2 ; continue }
			return $i
		}
		incr i
	}
	return -1
}

rio::syntax::register {C#} {cs csx} rio::syntax::csharp::scan

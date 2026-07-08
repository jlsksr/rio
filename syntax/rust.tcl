# rio — a Rust syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments and multi-line/raw strings colour
# as one unit.
#
# It colours: `//` (incl. `///`/`//!` doc) and `/* … */` comments as `comment`; `"…"`
# strings (which may span lines) and raw strings `r"…"`/`r#"…"#` (any hash count) as
# `string`, plus `'c'` char literals; numbers (with `0x`/`0o`/`0b`, `_` separators and
# `i32`/`u8`/`f64`/… suffixes) as `number`; keywords as `keyword`; `true`/`false` as
# `constant`; primitive type names and — by Rust's strict UpperCamelCase convention —
# any `TypeName` as `type`; a `fn` NAME and a called name (`name(`) as `function`; a
# `macro!` invocation as `function`; and an attribute `#[…]`/`#![…]` as `meta`.
#
# Two ambiguities are handled by the "colour only the unambiguous" rule: a `'a` with no
# closing quote is a LIFETIME (left plain, not mis-read as an unterminated char), and
# `/* */` block comments are treated as non-nesting (Rust nests them — a rare corner
# left as an honest gap rather than mis-colour the common case).

namespace eval rio::syntax::rust {}

set rio::syntax::rust::keywords {
	as async await break const continue crate dyn else enum extern fn for if impl in
	let loop match mod move mut pub ref return self Self static struct super trait type
	unsafe use where while union macro_rules yield box
}
set rio::syntax::rust::types {
	i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String
}
set rio::syntax::rust::constants {true false}
# After these, the next identifier names a type; after `fn`, a function.
set rio::syntax::rust::typeafter {struct enum union trait type impl}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */) | str (a "…" string across lines) | raw (a raw string, with
# `param` the number of `#` hashes to close). The START state "" falls through to code.
proc rio::syntax::rust::scan {line state param} {
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
			str {
				set j [_strend $line \" $i]
				if {$j < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state code }
			}
			raw {
				set ctok "\"[string repeat # $param]"
				set k [string first $ctok $line $i]
				if {$k < 0} { lappend spans $i $n string ; set i $n } \
				else { set e [expr {$k + [string length $ctok]}] ; lappend spans $i $e string ; set i $e ; set state code }
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
				} elseif {[regexp -indices {^b?r(#*)"} $sub m hm]} {
					# Raw string r"…" / r#"…"# / br"…" — hashes set the closing token.
					set pend ""
					set hashes [expr {[lindex $hm 1] - [lindex $hm 0] + 1}]
					set bodystart [expr {$i + [lindex $m 1] + 1}]
					set ctok "\"[string repeat # $hashes]"
					set k [string first $ctok $line $bodystart]
					if {$k < 0} { lappend spans $i $n string ; set i $n ; set state raw ; set param $hashes } \
					else { set e [expr {$k + [string length $ctok]}] ; lappend spans $i $e string ; set i $e }
				} elseif {$ch eq "\"" || [regexp {^b"} $sub]} {
					set pend ""
					set q0 [expr {$i + ($ch eq "\"" ? 0 : 1)}]
					set j [_strend $line \" [expr {$q0 + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n ; set state str } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "'"} {
					set pend ""
					if {[regexp -indices {^b?'(?:\\.|[^'\\])'} $sub m]} {
						# A char (or byte-char) literal.
						set len [expr {[lindex $m 1] + 1}]
						lappend spans $i [expr {$i + $len}] string ; incr i $len
					} else {
						# A lifetime ('a, 'static): leave plain, consume the tick + name.
						regexp -indices {^'[[:alpha:]_][[:alnum:]_]*} $sub m2
						if {[llength $m2]} { incr i [expr {[lindex $m2 1] + 1}] } else { incr i }
					}
				} elseif {($ch eq "#") && [regexp -indices {^#!?\[} $sub]} {
					set pend ""
					set k [string first "\]" $line $i]
					if {$k < 0} { lappend spans $i $n meta ; set i $n } \
					else { lappend spans $i [expr {$k + 1}] meta ; set i [expr {$k + 1}] }
				} elseif {[string match {[0-9]} $ch]} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][-+]?[0-9_]+)?)(?:[iuf](?:8|16|32|64|128|size))?} $sub m
					set len [expr {[lindex $m 1] + 1}]
					lappend spans $i [expr {$i + $len}] number ; incr i $len
				} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
					set len [expr {[lindex $m 1] + 1}]
					set word [string range $line $i [expr {$i + $len - 1}]]
					set after [string index $line [expr {$i + $len}]]
					set bang [string index $line [expr {$i + $len + 1}]]
					if {$pend ne ""} {
						lappend spans $i [expr {$i + $len}] $pend ; set pend ""
					} elseif {[lsearch -exact $constants $word] >= 0} {
						lappend spans $i [expr {$i + $len}] constant
					} elseif {[lsearch -exact $keywords $word] >= 0} {
						lappend spans $i [expr {$i + $len}] keyword
						if {[lsearch -exact $typeafter $word] >= 0} { set pend type }
						if {$word eq "fn"} { set pend function }
					} elseif {[lsearch -exact $types $word] >= 0} {
						lappend spans $i [expr {$i + $len}] type
					} elseif {$after eq "!" && $bang ne "="} {
						lappend spans $i [expr {$i + $len}] function
					} elseif {[regexp {^[A-Z]} $word]} {
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

# The end index (of the closing quote) of a "…" string beginning after column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::rust::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Rust {rs} rio::syntax::rust::scan

# rio — a C++ syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so block comments and raw string literals colour as
# one unit. It is C's highlighter (see c.tcl) grown up: the C++ keyword/type set, plus
# raw string literals.
#
# It colours: `//` and `/* … */` comments as `comment`; preprocessor directives
# (`#include`, `#define`, …) as `meta`, with a `<header>` on an include line as
# `string`; strings as `string` — `"…"` (with `u8`/`u`/`U`/`L` prefixes), `'c'` char
# literals, and raw string literals `R"delim(…)delim"` (which span lines, delimiter
# honoured); numbers (with `0x`/`0b`, `'` digit separators and int/float suffixes) as
# `number`; control/storage keywords as `keyword`; the built-in type names (and any
# `…_t`) as `type`; `nullptr`/`NULL`/`true`/`false` as `constant`; a called/defined name
# (`name(`) as `function`; and a `class`/`struct`/`union`/`enum`/`namespace`/`new` NAME
# as `type`. `template<…>` angle brackets are left plain (division/less-than ambiguous),
# per the "colour only the unambiguous" rule. Plain identifiers stay plain.

namespace eval rio::syntax::cpp {}

set rio::syntax::cpp::keywords {
	if else for while do switch case default break continue return goto
	typedef static extern const constexpr consteval constinit volatile register auto
	inline mutable thread_local struct union enum sizeof alignas alignof asm
	class namespace template typename this operator using friend explicit virtual
	override final public private protected new delete try catch throw noexcept decltype
	static_cast dynamic_cast reinterpret_cast const_cast typeid concept requires
	co_await co_yield co_return export module import and or not and_eq or_eq xor_eq
	not_eq bitand bitor xor compl signed unsigned
}
set rio::syntax::cpp::types {
	void char char8_t char16_t char32_t wchar_t short int long float double bool
	size_t ssize_t ptrdiff_t wchar_t intptr_t uintptr_t nullptr_t FILE va_list
}
set rio::syntax::cpp::constants {nullptr NULL true false}
# After these, the next identifier names a type.
set rio::syntax::cpp::typeafter {class struct union enum namespace new typename}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | comment (block /* */) | str (a "…"/'…' literal; `param` holds the quote) | raw (a
# raw string; `param` holds the ")delim\"" closing token). The START state "" falls
# through to the code arm.
proc rio::syntax::cpp::scan {line state param} {
	variable keywords
	variable types
	variable constants
	variable typeafter
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
				set j [_strend $line $q $i]
				if {$j < 0} { lappend spans $i $n string ; set i $n } \
				else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state code }
			}
			raw {
				set k [string first $param $line $i]
				if {$k < 0} { lappend spans $i $n string ; set i $n } \
				else { set e [expr {$k + [string length $param]}] ; lappend spans $i $e string ; set i $e ; set state code }
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
				} elseif {[regexp -indices {^(?:u8|u|U|L)?R"([^()\\ ]*)\(} $sub m dm]} {
					# Raw string R"delim(…)delim" — delimiter sets the closing token.
					set pend ""
					set bodystart [expr {$i + [lindex $m 1] + 1}]
					if {[lindex $dm 1] >= [lindex $dm 0]} {
						set delim [string range $line [expr {$i + [lindex $dm 0]}] [expr {$i + [lindex $dm 1]}]]
					} else { set delim "" }
					set ctok ")$delim\""
					set k [string first $ctok $line $bodystart]
					if {$k < 0} { lappend spans $i $n string ; set i $n ; set state raw ; set param $ctok } \
					else { set e [expr {$k + [string length $ctok]}] ; lappend spans $i $e string ; set i $e }
				} elseif {$ch eq "\"" || [regexp {^(?:u8|u|U|L)"} $sub]} {
					set pend ""
					regexp {^(?:u8|u|U|L)?} $sub pfx
					set q0 [expr {$i + [string length $pfx]}]
					set j [_strend $line \" [expr {$q0 + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n ; set state str ; set param [dict create q \"] } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {$ch eq "'" || [regexp {^(?:u8|u|U|L)'} $sub]} {
					set pend ""
					regexp {^(?:u8|u|U|L)?} $sub pfx
					set q0 [expr {$i + [string length $pfx]}]
					set j [_strend $line ' [expr {$q0 + 1}]]
					if {$j < 0} { lappend spans $i $n string ; set i $n } \
					else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
				} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
					set pend ""
					regexp -indices {^(?:0[xX][[:xdigit:]']+|0[bB][01']+|(?:[0-9][0-9']*\.?[0-9']*|\.[0-9']+)(?:[eE][-+]?[0-9]+)?)[uUlLfF]*} $sub m
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

# The end index (of the closing quote) of a "…" / '…' literal beginning at column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::cpp::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register {C++} {cpp cxx cc hpp hxx hh cppm ixx} rio::syntax::cpp::scan

# rio — a Python syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a linear, per-line state machine (see rio::syntax for the
# contract). It carries scan state across lines, so triple-quoted strings colour as
# one unit.
#
# It colours: `#` comments as `comment`; `'…'`/`"…"` and triple-quoted `'''…'''`/
# `"""…"""` strings — with the `r`/`b`/`u`/`f` prefixes — as `string` (triples span
# lines); numbers (int/float/hex/oct/bin/complex, `_` separators) as `number`;
# keywords as `keyword`; `True`/`False`/`None` as `constant`; a `@decorator` and a
# called/defined name (`name(`) and a `def` NAME as `function`; and a `class` NAME as
# `type`. Bare identifiers (variables, attributes) stay plain — Python can't tell them
# apart without running. Interpolation inside an f-string is not separately coloured
# (the whole string is one span) — a possible later refinement.

namespace eval rio::syntax::python {}

set rio::syntax::python::keywords {
	def class lambda if elif else for while break continue return yield pass
	try except finally raise with as import from global nonlocal del assert
	in is not and or async await match case
}
set rio::syntax::python::constants {True False None NotImplemented Ellipsis __debug__}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code
# | str3 (inside a triple-quoted string; `param` holds the `'''`/`"""` delimiter). The
# START state "" falls through to the code arm.
proc rio::syntax::python::scan {line state param} {
	variable keywords
	variable constants
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	while {$i < $n} {
		if {$state eq "str3"} {
			set qt [dict get $param q]
			set close [string first $qt $line $i]
			if {$close < 0} {
				if {$n > $i} { lappend spans $i $n string } ; set i $n
			} else {
				lappend spans $i [expr {$close + 3}] string ; set i [expr {$close + 3}]
				set state code
			}
			continue
		}
		set ch [string index $line $i]
		set sub [string range $line $i end]
		if {$ch eq "#"} {
			lappend spans $i $n comment ; set i $n
		} elseif {[regexp {^[rRbBuUfF]{0,2}('''|"""|'|")} $sub -> qt]} {
			set pend ""
			incr i [_string $line $i $qt spans state param]
		} elseif {$ch eq "@" && [string trim [string range $line 0 [expr {$i - 1}]]] eq "" \
				&& [regexp -indices {^@[[:alpha:]_][[:alnum:]_.]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] function ; incr i $len
		} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
			set pend ""
			regexp -indices {^(?:0[xX][[:xdigit:]_]+|0[oO][0-7_]+|0[bB][01_]+|(?:[0-9][0-9_]*\.?[0-9_]*|\.[0-9_]+)(?:[eE][-+]?[0-9_]+)?[jJ]?)} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len
		} elseif {[regexp -indices {^[[:alpha:]_][[:alnum:]_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			set after [string index $line [expr {$i + $len}]]
			if {$pend ne ""} {
				lappend spans $i [expr {$i + $len}] $pend ; set pend ""
			} elseif {[lsearch -exact $constants $word] >= 0} {
				lappend spans $i [expr {$i + $len}] constant
			} elseif {[lsearch -exact $keywords $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
				if {$word eq "def"} { set pend function } elseif {$word eq "class"} { set pend type }
			} elseif {$after eq "("} {
				lappend spans $i [expr {$i + $len}] function
			}
			incr i $len
		} else {
			incr i
		}
	}
	return [list $spans $state $param]
}

# Scan a string literal beginning at column `i` (the `qt` group is the opening quote —
# `'`, `"`, `'''`, or `"""` — with any r/b/u/f prefix already accounted for by the
# caller's match). Appends the `string` span(s) and, for an unterminated triple, sets
# the caller's `state`/`param` to carry it. Returns the length consumed on THIS line.
proc rio::syntax::python::_string {line i qt spansvar statevar paramvar} {
	upvar 1 $spansvar spans $statevar state $paramvar param
	set n [string length $line]
	# The quote starts after the prefix letters; recover the prefix length by re-matching.
	regexp {^[rRbBuUfF]{0,2}} [string range $line $i end] pfx
	set q0 [expr {$i + [string length $pfx]}]
	if {[string length $qt] == 3} {
		set close [string first $qt $line [expr {$q0 + 3}]]
		if {$close < 0} {
			lappend spans $i $n string ; set state str3 ; set param [dict create q $qt]
			return [expr {$n - $i}]
		}
		lappend spans $i [expr {$close + 3}] string
		return [expr {$close + 3 - $i}]
	}
	set close [_strend $line $qt [expr {$q0 + 1}]]
	if {$close < 0} { lappend spans $i $n string ; return [expr {$n - $i}] }
	lappend spans $i [expr {$close + 1}] string
	return [expr {$close + 1 - $i}]
}

# The end index (of the closing quote) of a single/double-quoted string beginning at
# column `i`, honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::python::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Python {py pyw pyi} rio::syntax::python::scan

# rio — a Lua syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a linear, per-line state machine (see rio::syntax for the contract). It
# carries scan state across lines, so long-bracket strings and long comments colour as
# one unit.
#
# It colours: `--` comments and long `--[[ … ]]` / `--[==[ … ]==]` block comments as
# `comment`; `'…'`/`"…"` strings (with backslash escapes) and long-bracket `[[ … ]]` /
# `[=[ … ]=]` strings (which span lines, no escapes) as `string`; numbers (decimal,
# float, exponent, and `0x` hex with `p` exponents) as `number`; keywords as `keyword`;
# `true`/`false`/`nil` as `constant`; the standard-library module names (`string`,
# `table`, `math`, `io`, `os`, …) as `type`; a `function` NAME and any called/defined
# name (`name(`) — including `obj:method(` — as `function`. Bare identifiers stay plain.
#
# Long brackets carry a LEVEL: the count of `=` between the brackets. An opener `[==[`
# is closed only by `]==]` with the same level, so `]]` inside a `[==[ … ]==]` body is
# literal. Both long strings and long comments share the machinery (`_longopen`,
# `_longclose`); the carried `param` records the level and which kind is open.

namespace eval rio::syntax::lua {}

set rio::syntax::lua::keywords {
	and break do else elseif end for function goto if in local not or repeat
	return then until while
}
set rio::syntax::lua::constants {true false nil}
# The standard-library namespaces (Lua has no user types, so these predeclared global
# tables are the closest analogue — coloured `type`, like Go's predeclared names).
set rio::syntax::lua::builtins {
	string table math io os coroutine debug utf8 package _G _ENV
}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}, a flat
# {c0 c1 type ...} of half-open COLUMN ranges (the rio::syntax contract). States: code |
# long (inside a long-bracket string OR comment spanning lines; `param` is a dict with
# `level` and `kind`). The START state "" falls through to the code arm.
proc rio::syntax::lua::scan {line state param} {
	variable keywords
	variable constants
	variable builtins
	set spans {}
	set n [string length $line]
	set i 0
	set pend ""
	if {$state eq ""} { set state code }
	while {$i < $n} {
		if {$state eq "long"} {
			set lvl [dict get $param level]
			set kind [dict get $param kind]
			set close [_longclose $line $i $lvl]
			if {$close < 0} { lappend spans $i $n $kind ; set i $n } \
			else { lappend spans $i $close $kind ; set i $close ; set state code ; set param "" }
			continue
		}
		set ch [string index $line $i]
		set two [string range $line $i [expr {$i + 1}]]
		set sub [string range $line $i end]
		if {$two eq "--"} {
			set lb [_longopen $line [expr {$i + 2}]]
			if {$lb ne ""} {
				lassign $lb lvl body
				set close [_longclose $line $body $lvl]
				if {$close < 0} {
					lappend spans $i $n comment ; set i $n
					set state long ; set param [dict create level $lvl kind comment]
				} else {
					lappend spans $i $close comment ; set i $close
				}
			} else {
				lappend spans $i $n comment ; set i $n
			}
		} elseif {$ch eq "\"" || $ch eq "'"} {
			set pend ""
			set j [_strend $line $ch [expr {$i + 1}]]
			if {$j < 0} { lappend spans $i $n string ; set i $n } \
			else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
		} elseif {$ch eq "\["} {
			set lb [_longopen $line $i]
			if {$lb ne ""} {
				set pend ""
				lassign $lb lvl body
				set close [_longclose $line $body $lvl]
				if {$close < 0} {
					lappend spans $i $n string ; set i $n
					set state long ; set param [dict create level $lvl kind string]
				} else {
					lappend spans $i $close string ; set i $close
				}
			} else {
				incr i
			}
		} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
			set pend ""
			regexp -indices {^(?:0[xX][[:xdigit:]]*\.?[[:xdigit:]]*(?:[pP][-+]?[0-9]+)?|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)} $sub m
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
				if {$word eq "function"} { set pend function }
			} elseif {[lsearch -exact $builtins $word] >= 0} {
				lappend spans $i [expr {$i + $len}] type
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

# A long-bracket OPENER at column `i`: `[`, then zero or more `=` (the level), then `[`.
# Returns {level bodystart} — bodystart the column just past the second `[` — or "" if
# there is no opener here. Shared by long strings (`[[`) and long comments (`--[[`).
proc rio::syntax::lua::_longopen {line i} {
	if {[string index $line $i] ne "\["} { return "" }
	set j [expr {$i + 1}]
	set eqs 0
	while {[string index $line $j] eq "="} { incr j ; incr eqs }
	if {[string index $line $j] eq "\["} { return [list $eqs [expr {$j + 1}]] }
	return ""
}

# The end column (just past the closing bracket) of a long span of level `lvl` whose
# body begins at column `i` — a `]`, then `lvl` `=`, then `]`; -1 if it does not close
# on this line. A lower/higher-level bracket in the body is not a close, so it's skipped.
proc rio::syntax::lua::_longclose {line i lvl} {
	set target "\][string repeat = $lvl]\]"
	set k [string first $target $line $i]
	if {$k < 0} { return -1 }
	return [expr {$k + [string length $target]}]
}

# The end index (of the closing quote) of a '…'/"…" string beginning at column `i`,
# honouring backslash escapes; -1 if it does not close on this line.
proc rio::syntax::lua::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq $q} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Lua {lua} rio::syntax::lua::scan

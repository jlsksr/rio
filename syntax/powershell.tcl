# rio — a PowerShell syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no
# external packages — a per-line scanner (see rio::syntax for the contract). It carries
# scan state across lines, so block comments (`<# … #>`) and multi-line strings colour
# correctly. Keyword lookup is case-INSENSITIVE (PowerShell is).
#
# It colours: `#` line comments and `<# … #>` block comments as `comment`; `"…"`
# (expandable) and `'…'` (literal) strings as `string`, both able to span lines; `$var`,
# `${var}`, `$global:x`, and the automatic `$_` / `$?` / `$args` as `variable`; the
# language keywords (`if`, `foreach`, `function`, `param`, `try`, …) as `keyword`; the
# `-eq` / `-match` / `-join` … style word-operators as `operator`; `[Type]` accelerators as
# `type`; `Verb-Noun` cmdlet names as `function`; and numbers. Honest gap: here-strings
# (`@"…"@`) are not recognised (their leading `@"` is treated as a normal string open).

namespace eval rio::syntax::powershell {}

# Language keywords → `keyword` (case-insensitive).
set rio::syntax::powershell::keywords {
	if elseif else switch for foreach while do until break continue return
	function filter param begin process end try catch finally throw trap
	class enum using namespace module in workflow parallel sequence data
	dynamicparam configuration exit hidden static
}
# Word-operators (`-eq`, `-match`, …) → `operator` (case-insensitive, the leading `-`).
set rio::syntax::powershell::operators {
	eq ne lt gt le ge match notmatch like notlike contains notcontains
	in notin and or not xor band bor bxor bnot shl shr is isnot as
	replace split join f ceq cne clt cgt cle cge cmatch clike
}

# scan ONE line starting in `state`/`param`; return {spans nextstate nextparam}.
# States: text | block (inside <# … #>) | str (inside a multi-line "…" / '…').
proc rio::syntax::powershell::scan {line state param} {
	variable keywords
	variable operators
	set spans {}
	set n [string length $line]
	set i 0
	while {$i < $n} {
		if {$state eq "block"} {
			set j [string first "#>" $line $i]
			if {$j < 0} { lappend spans $i $n comment ; set i $n } \
			else { lappend spans $i [expr {$j + 2}] comment ; set i [expr {$j + 2}] ; set state text }
			continue
		}
		if {$state eq "str"} {
			set j [_strend $line [dict get $param q] $i]
			if {$j < 0} { lappend spans $i $n string ; set i $n } \
			else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] ; set state text }
			continue
		}
		set ch [string index $line $i]
		set sub [string range $line $i end]
		set prev [string index $line [expr {$i - 1}]]
		set atword [expr {$i == 0 || ![regexp {[A-Za-z0-9_]} $prev]}]
		if {[string range $line $i [expr {$i + 1}]] eq "<#"} {
			set state block   ;# don't advance — the block arm emits the <# … span from here
		} elseif {$ch eq "#"} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\"" || $ch eq "'"} {
			set j [_strend $line $ch [expr {$i + 1}]]
			if {$j < 0} { lappend spans $i $n string ; set i $n ; set state str ; set param [dict create q $ch] } \
			else { lappend spans $i [expr {$j + 1}] string ; set i [expr {$j + 1}] }
		} elseif {$ch eq "\$"} {
			set len [_var $sub]
			if {$len > 0} { lappend spans $i [expr {$i + $len}] variable ; incr i $len } else { incr i }
		} elseif {$ch eq "\[" && [regexp -indices {^\[[A-Za-z_][A-Za-z0-9_.]*\]} $sub m]} {
			lappend spans $i [expr {$i + [lindex $m 1] + 1}] type ; incr i [expr {[lindex $m 1] + 1}]
		} elseif {$ch eq "-" && $atword && [regexp -indices {^-([A-Za-z]+)\y} $sub m op]} {
			set w [string tolower [string range $line [expr {$i + [lindex $op 0]}] [expr {$i + [lindex $op 1]}]]]
			if {[lsearch -exact $operators $w] >= 0} {
				lappend spans $i [expr {$i + [lindex $m 1] + 1}] operator
			}
			incr i [expr {[lindex $m 1] + 1}]
		} elseif {$atword && [string match {[0-9]} $ch]} {
			regexp -indices {^[0-9][0-9a-fA-FxXlLdD.]*} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len
		} elseif {[regexp -indices {^[A-Za-z_][A-Za-z0-9_]*(-[A-Za-z][A-Za-z0-9_]*)?} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			if {[string first "-" $word] >= 0} {
				lappend spans $i [expr {$i + $len}] function   ;# a Verb-Noun cmdlet
			} elseif {[lsearch -exact $keywords [string tolower $word]] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
			}
			incr i $len
		} else {
			incr i
		}
	}
	return [list $spans $state $param]
}

# The index of the closing quote `q` for a string body beginning at column i, or -1 if it
# does not close on this line. A `"…"` expands, so a backtick escapes the next char; a
# `'…'` is literal, where a doubled `''` is an escaped quote (not a close).
proc rio::syntax::powershell::_strend {line q i} {
	set n [string length $line]
	while {$i < $n} {
		set c [string index $line $i]
		if {$q eq "\"" && $c eq "`"} { incr i 2 ; continue }
		if {$q eq "'" && $c eq "'" && [string index $line [expr {$i + 1}]] eq "'"} { incr i 2 ; continue }
		if {$c eq $q} { return $i }
		incr i
	}
	return -1
}

# Length of a $-expansion at the START of `sub` (begins with `$`), or 0 for a bare `$`.
# Handles ${name}, $scope:name, $name, and the automatic $_ / $? / $$ / $^.
proc rio::syntax::powershell::_var {sub} {
	if {[regexp -indices {^\$\{[^\}]*\}} $sub m]}                         { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^\$[A-Za-z_][A-Za-z0-9_]*:[A-Za-z0-9_]+} $sub m]} { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^\$[A-Za-z_][A-Za-z0-9_]*} $sub m]}             { return [expr {[lindex $m 1] + 1}] }
	if {[regexp -indices {^\$[_?$^]} $sub m]}                            { return [expr {[lindex $m 1] + 1}] }
	return 0
}

rio::syntax::register PowerShell {ps1 psm1 psd1} rio::syntax::powershell::scan

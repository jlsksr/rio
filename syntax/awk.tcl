# rio — an awk syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a per-line scanner (see rio::syntax for the contract). awk strings do not
# span lines, so this carries no scan state.
#
# It colours: `#` comments as `comment`; `"…"` strings (with `\` escapes) as `string`; the
# special patterns `BEGIN` / `END` and the control keywords (`if`, `for`, `while`,
# `function`, `print`, …) as `keyword`; the built-in functions (`length`, `substr`, `split`,
# `gsub`, …) and any user function called as `name(` as `function`; the built-in variables
# (`NR`, `NF`, `FS`, `FILENAME`, …) as `variable`; field references (`$0`, `$1`, `$NF`) as
# `variable`; and numbers. Honest gap: `/regex/` literals are left plain — telling a regex
# from a division `/` needs context this per-line scanner doesn't track.

namespace eval rio::syntax::awk {}

# Special patterns + control keywords → `keyword`.
set rio::syntax::awk::keywords {
	BEGIN END function func if else while for do break continue next nextfile
	exit return delete in getline print printf
}
# Built-in functions → `function`.
set rio::syntax::awk::builtins {
	length substr index split sub gsub match sprintf sin cos atan2 exp log
	sqrt int rand srand tolower toupper system close fflush gensub systime
	strftime mktime and or xor compl lshift rshift
}
# Built-in variables → `variable`.
set rio::syntax::awk::vars {
	NR NF FS OFS ORS RS FILENAME FNR RSTART RLENGTH SUBSEP ARGC ARGV
	ENVIRON CONVFMT OFMT FIELDWIDTHS FPAT IGNORECASE RT PROCINFO
}

# scan ONE line (state unused — awk strings are single-line). Returns {spans "" ""}.
proc rio::syntax::awk::scan {line state param} {
	variable keywords
	variable builtins
	variable vars
	set spans {}
	set n [string length $line]
	set i 0
	while {$i < $n} {
		set ch [string index $line $i]
		set sub [string range $line $i end]
		if {$ch eq "#"} {
			lappend spans $i $n comment ; set i $n
		} elseif {$ch eq "\""} {
			set j [_strend $line [expr {$i + 1}]]
			set e [expr {$j < 0 ? $n : $j + 1}]
			lappend spans $i $e string ; set i $e
		} elseif {$ch eq "\$"} {
			if {[regexp -indices {^\$[0-9]+} $sub m] || [regexp -indices {^\$[A-Za-z_][A-Za-z0-9_]*} $sub m]} {
				set len [expr {[lindex $m 1] + 1}]
				lappend spans $i [expr {$i + $len}] variable ; incr i $len
			} else { incr i }
		} elseif {[string match {[0-9]} $ch] || ($ch eq "." && [string match {[0-9]} [string index $line [expr {$i + 1}]]])} {
			regexp -indices {^[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?} $sub m
			set len [expr {[lindex $m 1] + 1}]
			lappend spans $i [expr {$i + $len}] number ; incr i $len
		} elseif {[regexp -indices {^[A-Za-z_][A-Za-z0-9_]*} $sub m]} {
			set len [expr {[lindex $m 1] + 1}]
			set word [string range $line $i [expr {$i + $len - 1}]]
			set nx [string index $line [expr {$i + $len}]]
			if {[lsearch -exact $keywords $word] >= 0} {
				lappend spans $i [expr {$i + $len}] keyword
			} elseif {[lsearch -exact $vars $word] >= 0} {
				lappend spans $i [expr {$i + $len}] variable
			} elseif {$nx eq "("} {
				lappend spans $i [expr {$i + $len}] function
			} elseif {[lsearch -exact $builtins $word] >= 0} {
				lappend spans $i [expr {$i + $len}] function
			}
			incr i $len
		} else {
			incr i
		}
	}
	return [list $spans "" ""]
}

# The index of the closing `"` for a string body beginning at column i; -1 if unterminated
# on this line. Honours `\` escapes.
proc rio::syntax::awk::_strend {line i} {
	set n [string length $line]
	while {$i < $n} {
		set ch [string index $line $i]
		if {$ch eq "\\"} { incr i 2 ; continue }
		if {$ch eq "\""} { return $i }
		incr i
	}
	return -1
}

rio::syntax::register Awk {awk} rio::syntax::awk::scan

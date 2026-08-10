# rio — a sed syntax highlighter (AGENTS.md D32). PURE Tcl: no Tk, no I/O, no external
# packages — a per-line scanner (see rio::syntax for the contract). sed is command-
# oriented, not free-form; this walks a line command-by-command (they may be `;`-separated
# or `{ }`-grouped) and colours the structure. No scan state is carried.
#
# It colours: a `#` line comment as `comment`; numeric and `$` (last-line) addresses as
# `number` / `operator`, and a `/regex/` address as `string`; the command letter (`s`, `p`,
# `d`, `b`, …) as `keyword`; in an `s///` / `y///` command, the delimiters as `operator`,
# the two patterns as `string`, and the trailing flags as `attribute`; and a branch/label
# target (`: label`, `b label`, `t label`) as `function`. Text/filename arguments of
# `a`/`i`/`c`/`r`/`w` are left plain.

namespace eval rio::syntax::sed {}

# scan ONE line (state unused — sed scripts are line-local here). Returns {spans "" ""}.
proc rio::syntax::sed::scan {line state param} {
	set spans {}
	set n [string length $line]
	set i 0
	while {$i < $n && [string is space [string index $line $i]]} { incr i }
	if {$i < $n && [string index $line $i] eq "#"} {
		return [list [list $i $n comment] "" ""]
	}

	while {$i < $n} {
		set c [string index $line $i]
		if {[string is space $c] || $c eq ";" || $c eq "\{" || $c eq "\}"} { incr i ; continue }

		# ----- optional address(es): up to two, comma-separated -----
		for {set na 0} {$na < 2} {incr na} {
			set c [string index $line $i]
			if {[string match {[0-9]} $c]} {
				regexp -indices {^[0-9]+} [string range $line $i end] m
				set len [expr {[lindex $m 1] + 1}]
				lappend spans $i [expr {$i + $len}] number ; incr i $len
			} elseif {$c eq "\$"} {
				lappend spans $i [expr {$i + 1}] operator ; incr i
			} elseif {$c eq "/"} {
				set j [_field $line [expr {$i + 1}] "/"]
				set e [expr {$j < $n ? $j + 1 : $n}]
				lappend spans $i $e string ; set i $e
				while {$i < $n && [string match {[IM]} [string index $line $i]]} {
					lappend spans $i [expr {$i + 1}] attribute ; incr i
				}
			} elseif {$c eq "\\" && [string index $line [expr {$i + 1}]] ne ""} {
				set d [string index $line [expr {$i + 1}]]
				set j [_field $line [expr {$i + 2}] $d]
				set e [expr {$j < $n ? $j + 1 : $n}]
				lappend spans $i $e string ; set i $e
			} else break
			if {[string index $line $i] eq ","} {
				lappend spans $i [expr {$i + 1}] operator ; incr i ; continue
			}
			break
		}
		while {$i < $n && [string index $line $i] eq "!"} { lappend spans $i [expr {$i + 1}] operator ; incr i }
		while {$i < $n && [string is space [string index $line $i]]} { incr i }
		if {$i >= $n} break

		# ----- the command -----
		set cc [string index $line $i]
		if {$cc eq "s" || $cc eq "y"} {
			lappend spans $i [expr {$i + 1}] keyword
			set d [string index $line [expr {$i + 1}]]
			if {$d eq ""} { incr i ; continue }
			lappend spans [expr {$i + 1}] [expr {$i + 2}] operator
			set p [expr {$i + 2}]
			set j1 [_field $line $p $d]
			if {$j1 > $p} { lappend spans $p $j1 string }
			if {$j1 < $n} { lappend spans $j1 [expr {$j1 + 1}] operator }
			set p2 [expr {$j1 + 1}]
			set j2 [_field $line $p2 $d]
			if {$j2 > $p2} { lappend spans $p2 $j2 string }
			if {$j2 < $n} { lappend spans $j2 [expr {$j2 + 1}] operator }
			set i [expr {$j2 < $n ? $j2 + 1 : $n}]
			while {$i < $n} {
				set fc [string index $line $i]
				if {[string match {[gpiImMe0-9]} $fc]} {
					lappend spans $i [expr {$i + 1}] attribute ; incr i
				} elseif {$fc eq "w"} {
					lappend spans $i $n attribute ; set i $n
				} else break
			}
		} elseif {$cc eq "b" || $cc eq "t" || $cc eq "T" || $cc eq ":"} {
			lappend spans $i [expr {$i + 1}] keyword ; incr i
			while {$i < $n && [string is space [string index $line $i]]} { incr i }
			set s0 $i
			while {$i < $n} {
				set lc [string index $line $i]
				if {$lc eq ";" || $lc eq "\}" || [string is space $lc]} break
				incr i
			}
			if {$i > $s0} { lappend spans $s0 $i function }
		} elseif {[string first $cc "aicrRwW"] >= 0} {
			lappend spans $i [expr {$i + 1}] keyword ; set i $n
		} else {
			if {[string match {[A-Za-z=]} $cc]} { lappend spans $i [expr {$i + 1}] keyword }
			incr i
		}
	}
	return [list $spans "" ""]
}

# The index of the closing delimiter `d` for a field beginning at column i; `n` (the line
# length) if it is not closed on this line. Honours `\` escapes.
proc rio::syntax::sed::_field {line i d} {
	set n [string length $line]
	while {$i < $n} {
		set c [string index $line $i]
		if {$c eq "\\"} { incr i 2 ; continue }
		if {$c eq $d} { return $i }
		incr i
	}
	return $n
}

rio::syntax::register Sed {sed} rio::syntax::sed::scan

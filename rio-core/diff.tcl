# rio-core — line-level diff (AGENTS.md D28).
#
# A pure-logic LCS line diff: given two texts, produce the ordered list of
# operations that turns A into B, line by line. No Tk, no I/O, no protocol — it
# tests headless and carries no frontend shape, so a GUI compare view and a
# (future) TUI one consume the same ops (the O1 terminal-aware discipline).
#
# Texts split on "\n" exactly like the document model (D12): "a\nb\n" is three
# lines {a b {}}, so a diff lines up with the buffer it came from. The result is
# a list of flat dicts:
#
#   {tag equal  a <A-lineno> b <B-lineno>}   the same line in both
#   {tag delete a <A-lineno> b 0}            a line only in A (removed)
#   {tag insert a 0          b <B-lineno>}   a line only in B (added)
#
# Line numbers are 1-based; 0 means "no line on that side". A changed line shows
# up as a delete immediately followed by an insert — the frontend pairs adjacent
# delete/insert runs visually (red beside green), which reads as a replacement.
#
# Classic O(n*m) dynamic-programming LCS. For source-file sizes this is simple
# and fast enough (D12: a gap buffer / rope would be premature); very large
# inputs are out of scope for now, as elsewhere.

namespace eval rio::diff {}

proc rio::diff::lines {a b} {
	# Split into lines exactly as the document model does (document.tcl): an empty
	# text is one empty line, not zero lines, so line numbers stay 1-based and a
	# diff lines up with the buffer it came from (D12).
	set A [split $a "\n"] ; if {$A eq ""} { set A [list ""] }
	set B [split $b "\n"] ; if {$B eq ""} { set B [list ""] }
	set n [llength $A]
	set m [llength $B]

	# c(i,j) = length of the LCS of A[i..] and B[j..]; filled back-to-front so a
	# forward backtrack from (0,0) yields ops in document order. The last row and
	# column are the zero base cases.
	for {set j 0} {$j <= $m} {incr j} { set c($n,$j) 0 }
	for {set i 0} {$i <= $n} {incr i} { set c($i,$m) 0 }
	for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
		set ai [lindex $A $i]
		for {set j [expr {$m - 1}]} {$j >= 0} {incr j -1} {
			if {$ai eq [lindex $B $j]} {
				set c($i,$j) [expr {$c([expr {$i + 1}],[expr {$j + 1}]) + 1}]
			} else {
				set down  $c([expr {$i + 1}],$j)
				set right $c($i,[expr {$j + 1}])
				set c($i,$j) [expr {$down >= $right ? $down : $right}]
			}
		}
	}

	# Backtrack from (0,0): take the equal step when lines match, else step the
	# side whose LCS doesn't shrink (delete from A, or insert from B).
	set ops {}
	set i 0
	set j 0
	while {$i < $n && $j < $m} {
		if {[lindex $A $i] eq [lindex $B $j]} {
			lappend ops [dict create tag equal a [expr {$i + 1}] b [expr {$j + 1}]]
			incr i ; incr j
		} elseif {$c([expr {$i + 1}],$j) >= $c($i,[expr {$j + 1}])} {
			lappend ops [dict create tag delete a [expr {$i + 1}] b 0]
			incr i
		} else {
			lappend ops [dict create tag insert a 0 b [expr {$j + 1}]]
			incr j
		}
	}
	while {$i < $n} { lappend ops [dict create tag delete a [expr {$i + 1}] b 0] ; incr i }
	while {$j < $m} { lappend ops [dict create tag insert a 0 b [expr {$j + 1}]] ; incr j }
	return $ops
}

# rio-core — the document model (AGENTS.md D12).
#
# A document is an ordered list of line strings. Positions are "line.col"
# (1-based line, 0-based column) — the Tk text-widget index format (D12), so a
# GUI view maps near-free. The one edit primitive is a range replacement:
# replace [start, end) with text; insert and delete are degenerate cases.
#
# This module is pure logic — no Tk, no I/O, no protocol — so it tests headless.

namespace eval rio::doc {
	variable buffers {}   ;# dict: id -> {lines <list-of-strings> name <string>}
	variable nextid 0
}

# Create a buffer from text (a document always has at least one line) and return
# its id.
proc rio::doc::new {{text ""} {name untitled}} {
	variable buffers
	variable nextid
	set lines [split $text "\n"]
	if {$lines eq ""} { set lines [list ""] }
	set id [incr nextid]
	dict set buffers $id [dict create lines $lines name $name]
	return $id
}

proc rio::doc::exists {id} {
	variable buffers
	return [dict exists $buffers $id]
}

proc rio::doc::text {id} {
	return [join [lines $id] "\n"]
}

proc rio::doc::lines {id} {
	variable buffers
	if {![dict exists $buffers $id]} { error "no such buffer: $id" }
	return [dict get $buffers $id lines]
}

proc rio::doc::linecount {id} {
	return [llength [lines $id]]
}

# Replace [start, end) with text. Returns the text that was removed (so callers
# can build change events and, later, undo). Mutates the buffer in place.
proc rio::doc::replace {id start end text} {
	variable buffers
	lassign [_splice [lines $id] $start $end $text] newlines removed
	dict set buffers $id lines $newlines
	return $removed
}

# --- pure helpers (no buffer registry; unit-testable on a bare line list) ----

# Apply a range replacement to a line list. Returns {newlines removed}.
proc rio::doc::_splice {lines start end text} {
	lassign [_idx $start] sl sc
	lassign [_idx $end]   el ec
	set n [llength $lines]
	if {$sl < 1 || $sl > $n || $el < 1 || $el > $n} {
		error "index out of range: $start/$end (have $n line(s))"
	}
	set sli [expr {$sl - 1}]
	set eli [expr {$el - 1}]
	set startLine [lindex $lines $sli]
	set endLine   [lindex $lines $eli]
	set sc [_clamp $sc 0 [string length $startLine]]
	set ec [_clamp $ec 0 [string length $endLine]]
	if {$sli > $eli || ($sli == $eli && $sc > $ec)} {
		error "end before start: $start > $end"
	}
	set prefix  [string range $startLine 0 [expr {$sc - 1}]]
	set suffix  [string range $endLine $ec end]
	set removed [_range $lines $sli $sc $eli $ec]
	# split "" yields an empty list, not one empty segment — normalize so an
	# empty replacement (every delete) stays single-segment and inserts no line.
	set segs [split $text "\n"]
	if {$segs eq ""} { set segs [list ""] }
	if {[llength $segs] == 1} {
		set block [list $prefix[lindex $segs 0]$suffix]
	} else {
		set block [concat \
			[list $prefix[lindex $segs 0]] \
			[lrange $segs 1 end-1] \
			[list [lindex $segs end]$suffix]]
	}
	set newlines [concat \
		[lrange $lines 0 [expr {$sli - 1}]] \
		$block \
		[lrange $lines [expr {$eli + 1}] end]]
	return [list $newlines $removed]
}

# Extract the text spanning [sli.sc, eli.ec) from a line list (sli/eli 0-based).
proc rio::doc::_range {lines sli sc eli ec} {
	if {$sli == $eli} {
		return [string range [lindex $lines $sli] $sc [expr {$ec - 1}]]
	}
	set parts [list [string range [lindex $lines $sli] $sc end]]
	for {set i [expr {$sli + 1}]} {$i < $eli} {incr i} {
		lappend parts [lindex $lines $i]
	}
	lappend parts [string range [lindex $lines $eli] 0 [expr {$ec - 1}]]
	return [join $parts "\n"]
}

proc rio::doc::_idx {idx} {
	if {![regexp {^([0-9]+)\.([0-9]+)$} $idx -> l c]} {
		error "bad index: \"$idx\" (want line.col, e.g. 1.0)"
	}
	return [list $l $c]
}

proc rio::doc::_clamp {v lo hi} { expr {$v < $lo ? $lo : ($v > $hi ? $hi : $v)} }

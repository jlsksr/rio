# rio-core — the document model (AGENTS.md D12).
#
# A document is an ordered list of line strings. Positions are "line.col"
# (1-based line, 0-based column) — the Tk text-widget index format (D12), so a
# GUI view maps near-free. The one edit primitive is a range replacement:
# replace [start, end) with text; insert and delete are degenerate cases.
#
# This module is pure logic — no Tk, no I/O, no protocol — so it tests headless.

namespace eval rio::doc {
	variable buffers {}   ;# dict: id -> {lines <list-of-strings> name <string> meta <dict>}
	variable nextid 0
}

# Create a buffer from text (a document always has at least one line) and return
# its id. `meta` is an opaque per-buffer dict the model stores but never
# interprets — fs.* uses it to carry file path / encoding / line-ending so a
# save can preserve what an open detected (D22).
proc rio::doc::new {{text ""} {name untitled} {meta {}}} {
	variable buffers
	variable nextid
	set lines [split $text "\n"]
	if {$lines eq ""} { set lines [list ""] }
	set id [incr nextid]
	dict set buffers $id [dict create lines $lines name $name meta $meta undo {} redo {}]
	return $id
}

# Read or update a buffer's opaque metadata dict (see `new`).
proc rio::doc::meta {id} {
	variable buffers
	if {![dict exists $buffers $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	return [dict get $buffers $id meta]
}

proc rio::doc::setmeta {id key value} {
	variable buffers
	if {![dict exists $buffers $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	dict set buffers $id meta $key $value
}

proc rio::doc::exists {id} {
	variable buffers
	return [dict exists $buffers $id]
}

# Forget a buffer entirely (its id is not reused). The doc model never calls the
# builtin [close], so shadowing it here is safe.
proc rio::doc::close {id} {
	variable buffers
	if {![dict exists $buffers $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	set buffers [dict remove $buffers $id]
}

proc rio::doc::text {id} {
	return [join [lines $id] "\n"]
}

proc rio::doc::lines {id} {
	variable buffers
	if {![dict exists $buffers $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	return [dict get $buffers $id lines]
}

proc rio::doc::linecount {id} {
	return [llength [lines $id]]
}

# A summary of every open buffer, in creation order — the registry's key order,
# which Tcl dicts preserve. Each entry is a flat dict {buffer name path
# linecount}; `path` is "" for a buffer not backed by a file. View-local state
# (cursor, selection, tab order, modified) belongs to the frontend (D22), so it
# is deliberately absent here. This is the model's first non-flat result: a list
# of dicts, which the wire layer encodes as an array explicitly (D25).
proc rio::doc::inventory {} {
	variable buffers
	set out {}
	dict for {id b} $buffers {
		set meta [dict get $b meta]
		set path [expr {[dict exists $meta path] ? [dict get $meta path] : ""}]
		lappend out [dict create \
			buffer    $id \
			name      [dict get $b name] \
			path      $path \
			linecount [llength [dict get $b lines]]]
	}
	return $out
}

# Replace [start, end) with text. Returns the text that was removed (so callers
# can build change events and, later, undo). Mutates the buffer in place. This is
# the RAW primitive: it does not touch the undo history, so undo/redo can use it
# to reverse an edit without themselves being recorded.
proc rio::doc::replace {id start end text} {
	variable buffers
	lassign [_splice [lines $id] $start $end $text] newlines removed
	dict set buffers $id lines $newlines
	return $removed
}

# --- undo/redo (AGENTS.md O3) -----------------------------------------------
#
# A recorded edit is a replace that remembers enough to reverse itself: the range
# {start,end} and `text` it applied, plus the `removed` text it displaced. To
# UNDO, replace [start, advance(start,text)) — the span the inserted text now
# occupies — back with `removed`. To REDO, just replay the original replace, since
# undo restored the pre-edit state exactly. Applying a fresh edit invalidates the
# redo branch. (Coalescing consecutive keystrokes into one undo step is a later
# refinement; for now each edit is its own step.)

# A recording edit — what user-facing ops call. Returns the removed text.
proc rio::doc::edit {id start end text} {
	variable buffers
	set removed [replace $id $start $end $text]
	set rec [dict create start $start end $end text $text removed $removed]
	dict update buffers $id b {
		dict lappend b undo $rec
		dict set b redo {}
	}
	return $removed
}

# Undo the most recent recorded edit. Returns a change dict {start end text
# removed} describing the replacement applied (for a buffer.changed event), or ""
# if there is nothing to undo.
proc rio::doc::undo {id} {
	variable buffers
	set stack [dict get $buffers $id undo]
	if {![llength $stack]} { return "" }
	set rec [lindex $stack end]
	dict set buffers $id undo [lrange $stack 0 end-1]
	lassign [_recvals $rec] start end text removed
	set iend [_advance $start $text]
	replace $id $start $iend $removed
	dict update buffers $id b { dict lappend b redo $rec }
	return [dict create start $start end $iend text $removed removed $text]
}

# Redo the most recently undone edit. Returns a change dict or "".
proc rio::doc::redo {id} {
	variable buffers
	set stack [dict get $buffers $id redo]
	if {![llength $stack]} { return "" }
	set rec [lindex $stack end]
	dict set buffers $id redo [lrange $stack 0 end-1]
	lassign [_recvals $rec] start end text removed
	replace $id $start $end $text
	dict update buffers $id b { dict lappend b undo $rec }
	return [dict create start $start end $end text $text removed $removed]
}

proc rio::doc::_recvals {rec} {
	return [list [dict get $rec start] [dict get $rec end] \
		[dict get $rec text] [dict get $rec removed]]
}

# The index reached by inserting `text` starting at index `start` (D12 line.col).
proc rio::doc::_advance {start text} {
	lassign [_idx $start] sl sc
	set segs [split $text "\n"]
	if {$segs eq ""} { set segs [list ""] }
	if {[llength $segs] == 1} {
		return "$sl.[expr {$sc + [string length $text]}]"
	}
	set line [expr {$sl + [llength $segs] - 1}]
	return "$line.[string length [lindex $segs end]]"
}

# --- pure helpers (no buffer registry; unit-testable on a bare line list) ----

# Apply a range replacement to a line list. Returns {newlines removed}.
proc rio::doc::_splice {lines start end text} {
	lassign [_idx $start] sl sc
	lassign [_idx $end]   el ec
	set n [llength $lines]
	if {$sl < 1 || $sl > $n || $el < 1 || $el > $n} {
		rio::error::raise bad_index "index out of range: $start/$end (have $n line(s))"
	}
	set sli [expr {$sl - 1}]
	set eli [expr {$el - 1}]
	set startLine [lindex $lines $sli]
	set endLine   [lindex $lines $eli]
	set sc [_clamp $sc 0 [string length $startLine]]
	set ec [_clamp $ec 0 [string length $endLine]]
	if {$sli > $eli || ($sli == $eli && $sc > $ec)} {
		rio::error::raise bad_index "end before start: $start > $end"
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
		rio::error::raise bad_index "bad index: \"$idx\" (want line.col, e.g. 1.0)"
	}
	return [list $l $c]
}

proc rio::doc::_clamp {v lo hi} { expr {$v < $lo ? $lo : ($v > $hi ? $hi : $v)} }

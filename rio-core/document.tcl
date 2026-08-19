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
#
# `_splice` may CLAMP an out-of-range column to its line's end; the effective
# range can therefore differ from the caller's start/end. Pass `clampedVar` to
# receive that effective {start end} — `edit` records it so undo reverses the
# span the text actually occupies, not the raw (possibly out-of-range) request.
proc rio::doc::replace {id start end text {clampedVar ""}} {
	variable buffers
	lassign [_splice [lines $id] $start $end $text] newlines removed cstart cend
	dict set buffers $id lines $newlines
	if {$clampedVar ne ""} {
		upvar 1 $clampedVar clamped
		set clamped [list $cstart $cend]
	}
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
# The record keeps the CLAMPED start/end (see `replace`): a client may send a
# column past the line's end, and undo must reverse where the edit landed.
proc rio::doc::edit {id start end text} {
	variable buffers
	set removed [replace $id $start $end $text applied]
	lassign $applied cstart cend
	set rec [dict create start $cstart end $cend text $text removed $removed]
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

# --- search (AGENTS.md D36) ---------------------------------------------------
#
# Literal text search, computed HERE because the core owns the canonical text
# (D3): every frontend gets the same engine over the protocol instead of each
# re-implementing it against its own mirror. The queries are STATELESS — where
# the caret is, what was last searched, which match is highlighted are all
# frontend-local (D22) — so the caller passes a position in and gets a match
# back; no find state lives in the core. Matching works on character offsets
# over the joined text, so a needle may span lines.

# The char offset of line.col `idx` in a line list (a newline counts 1). A
# search is a query, not an edit, so an out-of-range position CLAMPS rather
# than raises: past the end means "the end".
proc rio::doc::_offset {lines idx} {
	lassign [_idx $idx] l c
	set n [llength $lines]
	if {$l < 1} { return 0 }
	if {$l > $n} { set l $n ; set c [string length [lindex $lines end]] }
	set off 0
	for {set i 0} {$i < $l - 1} {incr i} {
		incr off [expr {[string length [lindex $lines $i]] + 1}]
	}
	incr off [_clamp $c 0 [string length [lindex $lines [expr {$l - 1}]]]]
	return $off
}

# The line.col position at char offset `off` in a line list.
proc rio::doc::_at {lines off} {
	set l 1
	foreach line $lines {
		set len [string length $line]
		if {$off <= $len} { return "$l.$off" }
		set off [expr {$off - $len - 1}]
		incr l
	}
	return "[llength $lines].[string length [lindex $lines end]]"
}

# --- whole-word matching (D51) ----------------------------------------------
# A word char is a letter, digit, or underscore (Unicode letters included). A hit
# is "whole-word" when neither flank is a word char — the `\m…\M` feel without a
# regex. `hay` is the joined document, so a line break (a non-word char) bounds a
# hit at a line edge for free. The same rule the core-side find-in-files uses.
proc rio::doc::_wordchar {ch} { expr {$ch eq "_" || [string is alnum -strict $ch]} }
proc rio::doc::_bounded {hay i len} {
	set b [expr {$i - 1}]
	set a [expr {$i + $len}]
	if {$b >= 0 && [_wordchar [string index $hay $b]]} { return 0 }
	if {$a < [string length $hay] && [_wordchar [string index $hay $a]]} { return 0 }
	return 1
}
# The first occurrence of `ndl` (length `len`) at or after `start` that passes the
# whole-word test (or the first at all, when `ww` is 0), or -1. Rejected embedded
# hits are stepped over one char at a time so none in between is skipped.
proc rio::doc::_scan_fwd {hay ndl start len ww} {
	set i [string first $ndl $hay $start]
	while {$i >= 0} {
		if {!$ww || [_bounded $hay $i $len]} { return $i }
		set i [string first $ndl $hay [expr {$i + 1}]]
	}
	return -1
}
# The last such occurrence at or before `last`, or -1.
proc rio::doc::_scan_bwd {hay ndl last len ww} {
	set i [string last $ndl $hay $last]
	while {$i >= 0} {
		if {!$ww || [_bounded $hay $i $len]} { return $i }
		if {$i == 0} { return -1 }
		set i [string last $ndl $hay [expr {$i - 1}]]
	}
	return -1
}

# The next match of literal `needle` starting at or after `from` — or, with
# `backwards`, the nearest match starting before it — wrapping around the
# document. Returns {start end wrapped} or "" when the needle occurs nowhere.
# `nocase` folds case (Tcl's simple one-to-one mapping, so offsets are stable);
# `wholeword` keeps only word-bounded hits (D51).
proc rio::doc::find {id needle from {nocase 0} {backwards 0} {wholeword 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return "" }
	set hay [join $lines "\n"]
	set ndl $needle
	if {$nocase} { set hay [string tolower $hay] ; set ndl [string tolower $ndl] }
	set len [string length $ndl]
	set off [_offset $lines $from]
	set wrapped 0
	if {$backwards} {
		set i -1
		if {$off > 0} { set i [_scan_bwd $hay $ndl [expr {$off - 1}] $len $wholeword] }
		if {$i < 0} { set i [_scan_bwd $hay $ndl [string length $hay] $len $wholeword] ; set wrapped 1 }
	} else {
		set i [_scan_fwd $hay $ndl $off $len $wholeword]
		if {$i < 0} { set i [_scan_fwd $hay $ndl 0 $len $wholeword] ; set wrapped 1 }
	}
	if {$i < 0} { return "" }
	return [dict create \
		start   [_at $lines $i] \
		end     [_at $lines [expr {$i + $len}]] \
		wrapped $wrapped]
}

# Every match of `needle`, first to last, non-overlapping: a list of
# {start end} dicts (empty for none) — a frontend paints and counts them.
# `wholeword` drops hits flanked by a word char (D51).
proc rio::doc::matches {id needle {nocase 0} {wholeword 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return {} }
	set hay [join $lines "\n"]
	set ndl $needle
	if {$nocase} { set hay [string tolower $hay] ; set ndl [string tolower $ndl] }
	set len [string length $ndl]
	set out {}
	set i [string first $ndl $hay]
	while {$i >= 0} {
		if {!$wholeword || [_bounded $hay $i $len]} {
			lappend out [dict create \
				start [_at $lines $i] end [_at $lines [expr {$i + $len}]]]
		}
		set i [string first $ndl $hay [expr {$i + $len}]]
	}
	return $out
}

# Replace every match of `needle` with `text`, as ONE recorded edit: Replace All
# is one user action, so it is one undo step and one buffer.changed. The
# replacement segments come from the ORIGINAL text, so case outside the matches
# is untouched under `nocase`. Returns "" when nothing matched (no edit
# recorded), else a change dict {count start end text removed} spanning the
# whole document, ready to shape an event.
proc rio::doc::replace_all {id needle text {nocase 0} {wholeword 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return "" }
	set old [join $lines "\n"]
	set hay $old
	set ndl $needle
	if {$nocase} { set hay [string tolower $hay] ; set ndl [string tolower $ndl] }
	set len [string length $ndl]
	set out "" ; set count 0 ; set pos 0
	set i [string first $ndl $hay]
	while {$i >= 0} {
		# In whole-word mode, an embedded hit is left untouched: don't append the
		# replacement and don't advance `pos`, so the original text (including this
		# occurrence) is carried through by the next accepted match's copy span.
		if {!$wholeword || [_bounded $hay $i $len]} {
			append out [string range $old $pos [expr {$i - 1}]] $text
			incr count
			set pos [expr {$i + $len}]
		}
		set i [string first $ndl $hay [expr {$i + $len}]]
	}
	if {!$count} { return "" }
	append out [string range $old $pos end]
	set endpos "[llength $lines].[string length [lindex $lines end]]"
	edit $id 1.0 $endpos $out
	return [dict create count $count start 1.0 end $endpos text $out removed $old]
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
	# Report the CLAMPED range alongside the result: sc/ec were pinned to their
	# lines' bounds above, so "$sl.$sc"/"$el.$ec" is where the edit truly applied.
	return [list $newlines $removed "$sl.$sc" "$el.$ec"]
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

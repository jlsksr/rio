# rio-core — the document model (D12).
#
# A document is a list of line strings. A position is "line.col": 1-based line,
# 0-based column, Tk's text index format. The one edit is a range replacement:
# replace [start, end) with text. Insert and delete are special cases of it.
#
#   insert "x" at 1.2    replace 1.2 1.2 "x"
#   delete 1.2..1.5      replace 1.2 1.5 ""
#
# Pure logic: no Tk, no I/O, no protocol.

namespace eval rio::doc {
	variable buffers {}   ;# dict: id -> {lines name meta run seq undo undo_size redo redo_size}
	variable nextid 0
}

# Create a buffer from text and return its id. A document has at least one line.
# `meta` is stored, never interpreted: fs.* keeps path, encoding and line ending
# there (D22).
proc rio::doc::new {{text ""} {name untitled} {meta {}}} {
	variable buffers
	variable nextid
	set lines [split $text "\n"]
	if {$lines eq ""} { set lines [list ""] }
	set id [incr nextid]
	dict set buffers $id \
		[dict create lines $lines name $name meta $meta run 0 seq 0 \
			undo {} undo_size 0 redo {} redo_size 0]
	return $id
}

# Read or update a buffer's metadata dict (see `new`).
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

# Forget a buffer; its id is not reused. Shadows the builtin [close], which
# this namespace never calls.
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

# How many times this buffer's text has changed. `replace` bumps it, and every
# change goes through `replace`. Autosave (D132) compares it with the revision
# at its last write. Undoing back still counts as a change: one spare rewrite,
# never a skipped one.
proc rio::doc::revision {id} {
	variable buffers
	if {![dict exists $buffers $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	return [dict get $buffers $id seq]
}

# The text spanning [start, end). Strict, unlike `replace`: an index past its
# line's end is a bad_index, not clamped. The agent's selection scope (D113)
# must hear that its range is gone, not get another span.
proc rio::doc::range_text {id start end} {
	set lines [lines $id]
	lassign [_idx $start] sl sc
	lassign [_idx $end]   el ec
	set n [llength $lines]
	if {$sl < 1 || $sl > $n || $el < 1 || $el > $n
			|| $sc > [string length [lindex $lines $sl-1]]
			|| $ec > [string length [lindex $lines $el-1]]} {
		rio::error::raise bad_index "index out of range: $start/$end"
	}
	if {$sl > $el || ($sl == $el && $sc > $ec)} {
		rio::error::raise bad_index "end before start: $start > $end"
	}
	return [_range $lines [expr {$sl - 1}] $sc [expr {$el - 1}] $ec]
}

# Every open buffer in creation order, as {buffer name path linecount} dicts.
# `path` is "" for a buffer without a file. Cursor, selection, tab order and
# modified are the frontend's (D22), so they are not here.
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

# Replace [start, end) with text. Returns the removed text. The raw primitive:
# it records no undo step, so undo and redo can use it.
#
# A column past its line's end is clamped. `clampedVar` receives the range
# actually replaced, which `edit` records for undo.
proc rio::doc::replace {id start end text {clampedVar ""}} {
	variable buffers
	lassign [_splice [lines $id] $start $end $text] newlines removed cstart cend
	dict set buffers $id lines $newlines
	dict update buffers $id b { dict incr b seq }   ;# the change counter (`revision`, D132)
	if {$clampedVar ne ""} {
		upvar 1 $clampedVar clamped
		set clamped [list $cstart $cend]
	}
	return $removed
}

# --- undo/redo ---------------------------------------------------------------
#
# A step is a list {start end iend held}:
#
#   start end   the range the edit replaced
#   iend        where the text it put in ends
#   held        the half of the edit the document does NOT hold
#
#                the document has     the step holds
#   undo stack   the inserted text    the removed text
#   redo stack   the removed text     the inserted text
#
# Undo swaps the two halves and moves the step across; redo swaps them back. A text
# is therefore stored once. A list, not a dict: it is a third of the size (ADR-0146).
# A fresh edit empties the redo stack.
#
# --- the budget (ADR-0146) ---------------------------------------------------
#
# Each stack of each buffer may cost `undo_budget`: its held characters, plus
# `step_cost` a step. Over that, the oldest steps go. The newest always stays, so
# the last edit can be taken back whatever its size.
#
# --- coalescing (D90) ----------------------------------------------
#
# One undo takes back a word, not a keystroke. A one-character edit that
# continues the previous one is merged into its step:
#
#   type "the quick "    two steps: "the " and "quick "
#   Enter                always its own step
#
# - A blank closes the run.
# - One character joins at a time, in the run's direction: typing forward,
#   Backspace leftwards, Delete at one spot.
# - Anything else (a paste, Replace All, an agent edit) is its own step.
# - `run` says the top undo step is still open. Undo and redo clear it.
#
# coalesce=0 means "begin a new step here". The core cannot tell Delete pressed
# twice from vi's `x` twice, so the vi mode passes it on every normal-state key.
# It closes the run behind the edit only: vi's `i` and the word typed after it
# are one step.

namespace eval rio::doc {
	variable undo_budget 4194304   ;# per stack, per buffer: 4 MB of ASCII
	variable step_cost   300       ;# a step's own weight, rounded up from 279
}

# What a step counts against the budget.
proc rio::doc::_cost {step} {
	variable step_cost
	return [expr {$step_cost + [string length [lindex $step 3]]}]
}

# Put `step` on a buffer's `undo` or `redo` stack, then drop the oldest steps while
# the stack is over budget. Never the one just pushed.
proc rio::doc::_push {id stack step} {
	variable buffers
	variable undo_budget
	dict update buffers $id b {
		dict lappend b $stack $step
		set size [expr {[dict get $b ${stack}_size] + [_cost $step]}]
		set steps [dict get $b $stack]
		set drop 0
		while {$size > $undo_budget && $drop < [llength $steps] - 1} {
			set size [expr {$size - [_cost [lindex $steps $drop]]}]
			incr drop
		}
		if {$drop} { dict set b $stack [lrange $steps $drop end] }
		dict set b ${stack}_size $size
	}
}

# Take the newest step off a buffer's `undo` or `redo` stack. "" if it is empty.
proc rio::doc::_pop {id stack} {
	variable buffers
	set steps [dict get $buffers $id $stack]
	if {![llength $steps]} { return "" }
	set step [lindex $steps end]
	dict update buffers $id b {
		dict set b $stack [lrange $steps 0 end-1]
		dict incr b ${stack}_size -[_cost $step]
	}
	return $step
}

# A recorded edit, which is what the ops call. Returns the removed text.
# The step keeps the clamped range (see `replace`), where the edit landed.
proc rio::doc::edit {id start end text {coalesce 1}} {
	variable buffers
	set removed [replace $id $start $end $text applied]
	lassign $applied cstart cend
	set step [list $cstart $cend [_advance $cstart $text] $removed]
	set ch [_solo $text $removed]
	if {$coalesce && [dict get $buffers $id run]} {
		set top [lindex [dict get $buffers $id undo] end]
		set merged [_merge $top $step $ch]
		if {$merged ne ""} {
			_pop $id undo
			set step $merged
		}
	}
	_push $id undo $step
	dict update buffers $id b {
		dict set b run [_run_open $ch]
		dict set b redo {}
		dict set b redo_size 0
	}
	return $removed
}

# Replace a buffer's whole text: a reload from disk (D94). One undo step, so
# Ctrl+Z gets the old text back. coalesce=0 keeps it out of a typing run.
# Returns the change {start end text removed}, the shape of buffer.changed.
proc rio::doc::settext {id text} {
	set lines [lines $id]
	set endpos "[llength $lines].[string length [lindex $lines end]]"
	set removed [edit $id 1.0 $endpos $text 0]
	return [dict create start 1.0 end $endpos text $text removed $removed]
}

# `step`, an edit of the one character `ch`, folded into `top`, the step before it.
# "" when it cannot extend that step and must become a step of its own.
proc rio::doc::_merge {top step ch} {
	if {$top eq "" || $ch eq "" || $ch eq "\n"} { return "" }
	lassign $top  tstart tend tiend theld
	lassign $step start  end  iend  held
	if {$theld eq "" && $held eq ""} {
		# An insert run: the new character lands exactly where the last one ended.
		# The step stays a pure insert (start == end), so redo replays it whole.
		if {$start ne $tiend} { return "" }
		return [list $tstart $tend $iend ""]
	}
	if {$tiend eq $tstart && $iend eq $start} {
		# A delete run, either direction: Backspace removes the span ending where
		# the step starts, the Delete key removes again at the very same spot.
		if {$end eq $tstart} {
			set theld "$ch$theld"
			set tstart $start
		} elseif {$start eq $tstart} {
			append theld $ch
		} else {
			return ""
		}
		# `end` is what redo deletes again, so it must span the whole run.
		return [list $tstart [_advance $tstart $theld] $tstart $theld]
	}
	return ""
}

# May a following edit extend the step just recorded? Only mid-word: a blank
# closes the run, and so does anything but a single character (`ch` is "").
# `coalesce` is not asked: it breaks the run before this edit, not after.
proc rio::doc::_run_open {ch} {
	return [expr {$ch ne "" && ![string is space -strict $ch]}]
}

# The single character an edit inserts or deletes, or "" for any other edit.
proc rio::doc::_solo {text removed} {
	if {$removed eq "" && [string length $text] == 1}    { return $text }
	if {$text eq ""    && [string length $removed] == 1} { return $removed }
	return ""
}

# Undo the newest recorded edit. Returns the change applied, {start end text
# removed}, for a buffer.changed event; "" if there is nothing to undo.
proc rio::doc::undo {id} {
	variable buffers
	set step [_pop $id undo]
	if {$step eq ""} { return "" }
	dict set buffers $id run 0   ;# the run being typed into is gone (D90)
	lassign $step start end iend held
	set text [replace $id $start $iend $held]
	_push $id redo [list $start $end $iend $text]
	return [dict create start $start end $iend text $held removed $text]
}

# Redo the most recently undone edit. Returns a change dict or "".
proc rio::doc::redo {id} {
	variable buffers
	set step [_pop $id redo]
	if {$step eq ""} { return "" }
	dict set buffers $id run 0   ;# a redone step is closed: typing starts a new step
	lassign $step start end iend held
	set removed [replace $id $start $end $held]
	_push $id undo [list $start $end $iend $removed]
	return [dict create start $start end $end text $held removed $removed]
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

# --- search (D36) ---------------------------------------------------
#
# Search runs in the core, which owns the text (D3), so every frontend gets one
# engine. It is stateless: the caller passes a position and gets a match. Caret
# and last query are the frontend's (D22). Matching is on character offsets
# over the joined text, so a needle may span lines.

# The char offset of line.col `idx` in a line list (a newline counts 1).
# Out of range clamps: past the end means "the end".
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
# A word char is a letter, digit or underscore. A hit is whole-word when neither
# neighbour is a word char. A line break is not one, so it bounds a hit.
proc rio::doc::_wordchar {ch} { expr {$ch eq "_" || [string is alnum -strict $ch]} }
proc rio::doc::_bounded {hay i len} {
	set b [expr {$i - 1}]
	set a [expr {$i + $len}]
	if {$b >= 0 && [_wordchar [string index $hay $b]]} { return 0 }
	if {$a < [string length $hay] && [_wordchar [string index $hay $a]]} { return 0 }
	return 1
}
# The first occurrence of `ndl` (length `len`) at or after `start`, or -1.
# With `ww`, the first whole-word one.
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

# --- regex matching (D52 Phase C) ---------------------------------------------
# Every match of the Tcl-ARE pattern `pat` in `hay`, as {start end} char
# offsets, end exclusive. A zero-width match has start == end.
# - `-line`: `^` and `$` anchor at each line, `.` does not cross a newline.
# - An invalid pattern matches nothing: a half-typed regex is not an error.
# - `-about` counts the capture groups, to step over their submatches.
proc rio::doc::_regex_spans {hay pat nocase} {
	if {[catch {regexp -about -- $pat} about]} { return {} }
	set groups [lindex $about 0]
	set flags {-all -inline -indices -line}
	if {$nocase} { lappend flags -nocase }
	if {[catch {regexp {*}$flags -- $pat $hay} all]} { return {} }
	set spans {}
	set stride [expr {$groups + 1}]
	for {set i 0} {$i < [llength $all]} {incr i $stride} {
		lassign [lindex $all $i] s e
		lappend spans [list $s [expr {$e < $s ? $s : $e + 1}]]
	}
	return $spans
}

# The next match of `needle` at or after `from`, or with `backwards` the
# nearest one before it. Wraps around. Returns {start end wrapped}, or "" for
# no match.
# - `nocase` folds case.
# - `wholeword` keeps only word-bounded hits (D51).
# - `regex`: `needle` is a Tcl-ARE pattern, and `wholeword` is ignored.
proc rio::doc::find {id needle from {nocase 0} {backwards 0} {wholeword 0} {regex 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return "" }
	set hay [join $lines "\n"]
	if {$regex} {
		set spans [_regex_spans $hay $needle $nocase]
		if {![llength $spans]} { return "" }
		set off [_offset $lines $from]
		set wrapped 0
		if {$backwards} {
			set pick ""
			foreach sp $spans { if {[lindex $sp 0] < $off} { set pick $sp } }
			if {$pick eq ""} { set pick [lindex $spans end] ; set wrapped 1 }
		} else {
			set pick ""
			foreach sp $spans { if {[lindex $sp 0] >= $off} { set pick $sp ; break } }
			if {$pick eq ""} { set pick [lindex $spans 0] ; set wrapped 1 }
		}
		lassign $pick s e
		return [dict create start [_at $lines $s] end [_at $lines $e] wrapped $wrapped]
	}
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

# Every match of `needle`, first to last, non-overlapping, as {start end}
# dicts. Flags as in `find`.
proc rio::doc::matches {id needle {nocase 0} {wholeword 0} {regex 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return {} }
	set hay [join $lines "\n"]
	if {$regex} {
		set out {}
		foreach sp [_regex_spans $hay $needle $nocase] {
			lassign $sp s e
			lappend out [dict create start [_at $lines $s] end [_at $lines $e]]
		}
		return $out
	}
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

# --- line-grouped search (D52) ------------------------------------------------
# One matcher for find-in-files (project.search, D51) and open-buffer search
# (buffers.search): every line that contains `needle`, one row per line.
#
# Returns {matches occurrences}. A match is a dict:
#   line  — 1-based line number
#   cols  — 1-based start column of every hit on the line
#   lens  — char length of each hit, parallel to `cols`
#   col   — the first start, the jump target
#   text  — the line, capped to `textcap` chars
# `occurrences` counts every hit. No row cap: the caller truncates.
# Flags as in `find`.
proc rio::doc::grep_lines {lines needle nocase wholeword {textcap 200} {regex 0}} {
	set matches {}
	set occ 0
	set ln 0
	foreach line $lines {
		incr ln
		lassign [_line_hits $line $needle $nocase $wholeword $regex] cols lens
		if {[llength $cols] == 0} continue
		incr occ [llength $cols]
		lappend matches [dict create line $ln col [lindex $cols 0] cols $cols lens $lens \
			text [string range $line 0 [expr {$textcap - 1}]]]
	}
	return [list $matches $occ]
}

# The hits of `needle` on one line, as parallel {cols lens} lists: 1-based
# start columns and char lengths. Flags as in `find`.
proc rio::doc::_line_hits {line needle nocase wholeword regex} {
	set cols {} ; set lens {}
	if {$regex} {
		foreach sp [_regex_spans $line $needle $nocase] {
			lassign $sp s e
			lappend cols [expr {$s + 1}] ; lappend lens [expr {$e - $s}]
		}
		return [list $cols $lens]
	}
	set h $line ; set ndl $needle
	if {$nocase} { set h [string tolower $line] ; set ndl [string tolower $needle] }
	set nlen [string length $ndl]
	set from 0
	while {1} {
		set i [string first $ndl $h $from]
		if {$i < 0} break
		if {!$wholeword || [_bounded $h $i $nlen]} { lappend cols [expr {$i + 1}] ; lappend lens $nlen }
		set from [expr {$i + $nlen}]
	}
	return [list $cols $lens]
}

# Replace every match of `needle` with `text` as one recorded edit: one undo
# step, one buffer.changed. Returns "" when nothing matched, else the change
# {count start end text removed} over the whole document.
proc rio::doc::replace_all {id needle text {nocase 0} {wholeword 0} {regex 0}} {
	set lines [lines $id]
	if {$needle eq ""} { return "" }
	set old [join $lines "\n"]
	lassign [_replace_text $old $needle $text $nocase $wholeword $regex] out count
	if {!$count} { return "" }
	set endpos "[llength $lines].[string length [lindex $lines end]]"
	edit $id 1.0 $endpos $out
	return [dict create count $count start 1.0 end $endpos text $out removed $old]
}

# Replace every match of `needle` with `text` in the string `old`. Returns
# {newtext count}; no match, or an invalid pattern, gives {<old> 0}.
# A pure string function, so `replace_all` (an open buffer) and project.replace
# (a closed file, D52) share it.
# - Literal: the text between matches is copied from `old`, so `nocase` leaves
#   its case alone. A hit that is not a whole word stays in place.
# - `regex`: `text` is a regsub replacement; `\1` and `&` work.
proc rio::doc::_replace_text {old needle text nocase wholeword {regex 0}} {
	if {$regex} {
		set flags {-all -line}
		if {$nocase} { lappend flags -nocase }
		if {[catch {regsub {*}$flags -- $needle $old $text out} count]} { return [list $old 0] }
		return [list $out $count]
	}
	set hay $old
	set ndl $needle
	if {$nocase} { set hay [string tolower $hay] ; set ndl [string tolower $ndl] }
	set len [string length $ndl]
	set out "" ; set count 0 ; set pos 0
	set i [string first $ndl $hay]
	while {$i >= 0} {
		if {!$wholeword || [_bounded $hay $i $len]} {
			append out [string range $old $pos [expr {$i - 1}]] $text
			incr count
			set pos [expr {$i + $len}]
		}
		set i [string first $ndl $hay [expr {$i + $len}]]
	}
	append out [string range $old $pos end]
	return [list $out $count]
}

# --- pure helpers: they take a line list, not a buffer ----------------------

# Apply a range replacement to a line list.
# Returns {newlines removed start end}, the range as clamped.
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
	# split "" gives an empty list; a delete needs one empty segment.
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

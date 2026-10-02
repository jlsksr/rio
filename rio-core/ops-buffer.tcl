# rio-core — the buffer.* op namespace (D11, D12).
#
# Thin handlers: pick the buffer, call rio::doc, shape the events.

namespace eval rio::ops {
	variable default ""   ;# id of the buffer used when a request omits `buffer`
}

proc rio::ops::_bufid {params} {
	variable default
	if {[dict exists $params buffer]} { return [dict get $params buffer] }
	return $default
}

# buffer.new {?name?} -> {buffer, name} ; mints an empty buffer (a scratch tab).
proc rio::ops::buffer_new {params} {
	set name [expr {[dict exists $params name] ? [dict get $params name] : "untitled"}]
	set id [rio::doc::new "" $name]
	return [dict create result [dict create buffer $id name $name]]
}
rio::dispatch::register buffer.new rio::ops::buffer_new

# buffer.close {?buffer?} -> {} ; forgets a buffer (closing its tab).
proc rio::ops::buffer_close {params} {
	set id [_bufid $params]
	if {![rio::doc::exists $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	# Drop its recovery copy (D132), before the close: the meta names the file.
	rio::autosave::discard $id
	rio::autosave::forget $id
	rio::doc::close $id
	return [dict create result {}]
}
rio::dispatch::register buffer.close rio::ops::buffer_close

# buffer.setpath {buffer, path} -> {} ; point a buffer at another file without
# writing. After a file-pane Rename (D48), so the next Save does not recreate
# the old name.
proc rio::ops::buffer_setpath {params} {
	set id [_bufid $params]
	if {![rio::doc::exists $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	if {![dict exists $params path]} {
		rio::error::raise bad_request "buffer.setpath requires a path"
	}
	# A recovery copy is keyed by path: drop the old name's (D132). The new
	# name gets one at the next sweep.
	set was [rio::doc::meta $id]
	if {[dict exists $was path]} { rio::autosave::discard_path [dict get $was path] }
	rio::doc::setmeta $id path [dict get $params path]
	return [dict create result {}]
}
rio::dispatch::register buffer.setpath rio::ops::buffer_setpath

# buffer.list -> {buffers <array of {buffer,name,path,linecount}>}
# The open buffers, in creation order.
proc rio::ops::buffer_list {params} {
	return [dict create result [dict create buffers [rio::doc::inventory]]]
}
rio::dispatch::register buffer.list rio::ops::buffer_list

# How much text one chunked buffer.text reply carries, in characters (D126).
# Whole lines only, so a chunk may run over by its last line. 256 KB, because
# tcllib's json2dict is quadratic in the length of one JSON string; smaller
# chunks gain nothing and cost a round trip each.
namespace eval rio::ops { variable text_chunk_chars 262144 }

# buffer.text {?buffer?}                   -> {text <whole document>}
# buffer.text {?buffer? start <line> ?max <chars>?}
#                                          -> {text <chunk> next <line> eof 0|1}
#
# Without `start`: the whole document in one reply. With `start` (a 1-based
# line): one chunk; ask again from `next` until `eof`. The chunks concatenate
# to the document: every chunk but the last ends in its newline.
proc rio::ops::buffer_text {params} {
	variable text_chunk_chars
	set id [_bufid $params]
	if {![dict exists $params start]} {
		return [dict create result [dict create text [rio::doc::text $id]]]
	}
	set start [dict get $params start]
	if {$start < 1} { set start 1 }
	set max [expr {[dict exists $params max] ? [dict get $params max] : $text_chunk_chars}]
	if {$max < 1} { set max 1 }
	set lines [rio::doc::lines $id]
	set n [llength $lines]
	if {$start > $n} {
		return [dict create result [dict create text "" next $start eof 1]]
	}
	set out {} ; set len 0 ; set L $start
	while {$L <= $n && $len < $max} {
		set s [lindex $lines [expr {$L - 1}]]
		lappend out $s
		incr len [expr {[string length $s] + 1}]
		incr L
	}
	set text [join $out "\n"]
	set eof [expr {$L > $n}]
	if {!$eof} { append text "\n" }   ;# the separator to the line this chunk stops before
	return [dict create result [dict create text $text next $L eof [expr {$eof ? 1 : 0}]]]
}
rio::dispatch::register buffer.text rio::ops::buffer_text

# buffer.replace {start, end, text, ?coalesce?} -> {} ; emits buffer.changed.
# `coalesce` (default 1) lets the edit join the undo step being typed (D90,
# see rio::doc). A frontend sends 0 for a discrete command.
proc rio::ops::buffer_replace {params} {
	set id [_bufid $params]
	set start [dict get $params start]
	set end   [dict get $params end]
	set text  [dict get $params text]
	set removed [rio::doc::edit $id $start $end $text \
		[_flag_dflt $params coalesce 1]]                 ;# recorded for undo (O3)
	set ev [dict create event buffer.changed params \
		[dict create buffer $id start $start end $end text $text removed $removed]]
	return [dict create result {} events [list $ev]]
}
rio::dispatch::register buffer.replace rio::ops::buffer_replace

# --- search (D36) ---------------------------------------------------
# Stateless queries over the canonical text (D3): the caller carries the caret
# and the options (D22), the core computes the matches. See rio::doc.

# The non-empty search needle a search op requires, or a bad_request.
proc rio::ops::_needle {params op} {
	if {![dict exists $params needle] || [dict get $params needle] eq ""} {
		rio::error::raise bad_request "$op requires a non-empty needle"
	}
	return [dict get $params needle]
}

# An optional boolean param as 0/1 (absent means off). Accepts JSON booleans
# and 0/1 strings alike.
proc rio::ops::_flag {params key} {
	return [expr {[dict exists $params $key] && [dict get $params $key] ? 1 : 0}]
}

# The same, for a flag that is ON when absent (`_flag` can only default off).
proc rio::ops::_flag_dflt {params key dflt} {
	if {![dict exists $params $key]} { return $dflt }
	return [expr {[dict get $params $key] ? 1 : 0}]
}

# buffer.find {needle, ?from?, ?nocase?, ?backwards?, ?wholeword?, ?buffer?} ->
#   {found 0} | {found 1, start, end, wrapped} ; the next match from `from`
# (default 1.0), wrapping around the document.
proc rio::ops::buffer_find {params} {
	set id [_bufid $params]
	set needle [_needle $params buffer.find]
	# No expr around the index: it would turn column 1.10 into the float 1.1.
	set from 1.0
	if {[dict exists $params from]} { set from [dict get $params from] }
	set m [rio::doc::find $id $needle $from \
		[_flag $params nocase] [_flag $params backwards] [_flag $params wholeword] \
		[_flag $params regex]]
	if {$m eq ""} { return [dict create result [dict create found 0]] }
	return [dict create result [dict merge [dict create found 1] $m]]
}
rio::dispatch::register buffer.find rio::ops::buffer_find

# buffer.matches {needle, ?nocase?, ?wholeword?, ?buffer?} -> {count, matches:[{start,end}]}
# Every match, first to last: a frontend's highlight-all and match count.
proc rio::ops::buffer_matches {params} {
	set id [_bufid $params]
	set ms [rio::doc::matches $id [_needle $params buffer.matches] \
		[_flag $params nocase] [_flag $params wholeword] [_flag $params regex]]
	return [dict create result [dict create count [llength $ms] matches $ms]]
}
rio::dispatch::register buffer.matches rio::ops::buffer_matches

# buffer.replace_all {needle, text, ?nocase?, ?wholeword?, ?buffer?} -> {count} ;
# replaces every match as one edit: one undo step, one buffer.changed.
proc rio::ops::buffer_replace_all {params} {
	set id [_bufid $params]
	set needle [_needle $params buffer.replace_all]
	if {![dict exists $params text]} {
		rio::error::raise bad_request "buffer.replace_all requires text"
	}
	set ch [rio::doc::replace_all $id $needle [dict get $params text] \
		[_flag $params nocase] [_flag $params wholeword] [_flag $params regex]]
	if {$ch eq ""} { return [dict create result [dict create count 0]] }
	set ev [dict create event buffer.changed params [dict create buffer $id \
		start [dict get $ch start] end [dict get $ch end] \
		text [dict get $ch text] removed [dict get $ch removed]]]
	return [dict create result [dict create count [dict get $ch count]] \
		events [list $ev]]
}
rio::dispatch::register buffer.replace_all rio::ops::buffer_replace_all

# buffers.search {needle, ?nocase?, ?wholeword?, ?only?} ->
#   {count, files, truncated, results:[{buffer, name, path, matches:[{line,col,cols,text}]}]}
# project.search's shape (D51), over the open buffers' live text, unsaved
# edits included: the Search panel's "Open docs" and "Current doc" (D52).
# `only` (a buffer id) searches that buffer alone. Same matcher as project
# search: rio::doc::grep_lines. `truncated` is always 0: no row cap.
proc rio::ops::buffers_search {params} {
	set needle [_needle $params buffers.search]
	set nocase [_flag $params nocase]
	set wholeword [_flag $params wholeword]
	set regex [_flag $params regex]
	set only [expr {[dict exists $params only] ? [dict get $params only] : ""}]
	set results {}
	set total 0
	foreach b [rio::doc::inventory] {
		set id [dict get $b buffer]
		if {$only ne "" && $id ne $only} continue
		lassign [rio::doc::grep_lines [rio::doc::lines $id] $needle $nocase $wholeword 200 $regex] \
			matches occ
		if {[llength $matches] == 0} continue
		incr total $occ
		lappend results [dict create buffer $id name [dict get $b name] \
			path [dict get $b path] matches $matches]
	}
	return [dict create result [dict create count $total files [llength $results] \
		truncated 0 results $results]]
}
rio::dispatch::register buffers.search rio::ops::buffers_search

# --- staleness: a buffer notices the file changed under it (D94) ---
#
# The core detects it: with a remote core the file is on the server (D29).
# It compares the mtime and size stamped at open and save with a stat now.
#
#   buffers.stale    what went stale?
#   buffers.reload   take the disk version
#   buffers.stamp    I have seen this version, keep my text
#
# The last two take lists: a `git pull` can stale every tab at once, and that
# should cost one round trip.

# buffers.stale {} -> {stale:[{buffer, path, gone}]}
# Every stamped buffer whose file no longer matches its stamp. `gone 1`: the
# file is not there. A buffer without a path or a stamp is skipped.
proc rio::ops::buffers_stale {params} {
	set out {}
	foreach b [rio::doc::inventory] {
		set id [dict get $b buffer]
		set path [dict get $b path]
		if {$path eq ""} continue
		set meta [rio::doc::meta $id]
		if {![dict exists $meta mtime] || ![dict exists $meta size]} continue
		set st [rio::fs::stamp $path]
		if {![dict size $st]} {
			lappend out [dict create buffer $id path $path gone 1]
			continue
		}
		if {[dict get $st mtime] == [dict get $meta mtime] \
		 && [dict get $st size]  == [dict get $meta size]} continue
		lappend out [dict create buffer $id path $path gone 0]
	}
	return [dict create result [dict create stale $out]]
}
rio::dispatch::register buffers.stale rio::ops::buffers_stale

# buffers.reload {buffers:[id ...]} -> {reloaded:[{buffer, path, encoding, eol, linecount}],
#                                       failed:[{buffer, message}]}
# Re-read each file, replace the buffer's text as one undo step, re-stamp.
# - Emits one buffer.changed per buffer, before this reply.
# - Encoding and EOL are detected again: the file may have been rewritten.
# - A file that cannot be read goes to `failed`; the others still reload.
proc rio::ops::buffers_reload {params} {
	if {![dict exists $params buffers]} {
		rio::error::raise bad_request "buffers.reload requires buffers"
	}
	set done {}
	set failed {}
	set evs {}
	foreach id [dict get $params buffers] {
		if {![rio::doc::exists $id]} {
			lappend failed [dict create buffer $id message "no such buffer: $id"]
			continue
		}
		set meta [rio::doc::meta $id]
		set path [expr {[dict exists $meta path] ? [dict get $meta path] : ""}]
		if {$path eq ""} {
			lappend failed [dict create buffer $id message "buffer has no associated file"]
			continue
		}
		if {[catch {rio::fs::read $path} info]} {
			lappend failed [dict create buffer $id message $info]
			continue
		}
		set ch [rio::doc::settext $id [dict get $info text]]
		foreach k {encoding eol bom} { rio::doc::setmeta $id $k [dict get $info $k] }
		rio::ops::_restamp $id $path
		# The disk version was taken: drop the recovery copy (D132).
		rio::autosave::discard $id
		rio::autosave::note_saved $id
		lappend evs [dict create event buffer.changed params [dict create buffer $id \
			start [dict get $ch start] end [dict get $ch end] \
			text [dict get $ch text] removed [dict get $ch removed]]]
		lappend done [dict create buffer $id path $path \
			encoding [dict get $info encoding] eol [dict get $info eol] \
			linecount [rio::doc::linecount $id]]
	}
	return [dict create result [dict create reloaded $done failed $failed] events $evs]
}
rio::dispatch::register buffers.reload rio::ops::buffers_reload

# buffers.recover {buffer} -> {buffer path linecount}
# Take the recovery copy autosave left for this buffer's file (D132), after
# file.open reported one and the user said yes. Like a reload: one undo step,
# one buffer.changed.
# - The file is not written, so its stamp and encoding facts stay as they are.
# - The copy stays: the buffer still differs from the file.
# - note_saved: copy and buffer agree, so the next sweep writes nothing.
proc rio::ops::buffers_recover {params} {
	set id [_bufid $params]
	if {![rio::doc::exists $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	set meta [rio::doc::meta $id]
	set path [expr {[dict exists $meta path] ? [dict get $meta path] : ""}]
	if {$path eq ""} {
		rio::error::raise bad_request "buffers.recover: buffer $id has no associated file"
	}
	set rec [rio::autosave::recovery_for $path]
	if {![dict exists $rec path]} {
		rio::error::raise io_error "nothing to recover for $path"
	}
	if {[catch {rio::fs::read [dict get $rec path]} info]} {
		rio::error::raise io_error $info
	}
	set ch [rio::doc::settext $id [dict get $info text]]
	rio::autosave::note_saved $id
	return [dict create \
		result [dict create buffer $id path $path linecount [rio::doc::linecount $id]] \
		events [list [dict create event buffer.changed params [dict create buffer $id \
			start [dict get $ch start] end [dict get $ch end] \
			text [dict get $ch text] removed [dict get $ch removed]]]]]
}
rio::dispatch::register buffers.recover rio::ops::buffers_recover

# buffers.stamp {buffers:[id ...]} -> {stamped N}
# "Keep my edits": record what is on disk now, leave the text. The buffer is
# no longer reported stale, until the file changes again. A buffer without a
# path, or whose file is gone, is not counted.
proc rio::ops::buffers_stamp {params} {
	if {![dict exists $params buffers]} {
		rio::error::raise bad_request "buffers.stamp requires buffers"
	}
	set n 0
	foreach id [dict get $params buffers] {
		if {![rio::doc::exists $id]} continue
		set meta [rio::doc::meta $id]
		if {![dict exists $meta path] || [dict get $meta path] eq ""} continue
		if {[dict size [rio::ops::_restamp $id [dict get $meta path]]]} { incr n }
	}
	return [dict create result [dict create stamped $n]]
}
rio::dispatch::register buffers.stamp rio::ops::buffers_stamp

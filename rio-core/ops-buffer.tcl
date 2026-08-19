# rio-core — the buffer.* op namespace (AGENTS.md D11, D12).
#
# Thin handlers that bridge the protocol to the document model. They hold no
# logic of their own beyond picking a target buffer and shaping events; the
# real work lives in rio::doc.

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
	rio::doc::close $id
	return [dict create result {}]
}
rio::dispatch::register buffer.close rio::ops::buffer_close

# buffer.setpath {buffer, path} -> {} ; repoint a buffer at a new file WITHOUT writing.
# Only the stored path changes — the same doc meta `file.save`'s save-as updates. This
# is what makes a file-pane Rename (D48) durable for an open buffer: without it the
# retargeted tab's next Save would recreate the OLD name from the core's stale path.
proc rio::ops::buffer_setpath {params} {
	set id [_bufid $params]
	if {![rio::doc::exists $id]} { rio::error::raise no_buffer "no such buffer: $id" }
	if {![dict exists $params path]} {
		rio::error::raise bad_request "buffer.setpath requires a path"
	}
	rio::doc::setmeta $id path [dict get $params path]
	return [dict create result {}]
}
rio::dispatch::register buffer.setpath rio::ops::buffer_setpath

# buffer.list -> {buffers <array of {buffer,name,path,linecount}>}
# The core's inventory of open buffers, in creation order. This is the first op
# whose result is non-flat — `buffers` is an array — so the wire encoder is told
# the shape rather than guessing it (D25); see rio::wire.
proc rio::ops::buffer_list {params} {
	return [dict create result [dict create buffers [rio::doc::inventory]]]
}
rio::dispatch::register buffer.list rio::ops::buffer_list

# buffer.text -> {text <whole document>}
proc rio::ops::buffer_text {params} {
	return [dict create result [dict create text [rio::doc::text [_bufid $params]]]]
}
rio::dispatch::register buffer.text rio::ops::buffer_text

# buffer.replace {start, end, text} -> {} ; emits buffer.changed to all views.
proc rio::ops::buffer_replace {params} {
	set id [_bufid $params]
	set start [dict get $params start]
	set end   [dict get $params end]
	set text  [dict get $params text]
	set removed [rio::doc::edit $id $start $end $text]   ;# recorded for undo (O3)
	set ev [dict create event buffer.changed params \
		[dict create buffer $id start $start end $end text $text removed $removed]]
	return [dict create result {} events [list $ev]]
}
rio::dispatch::register buffer.replace rio::ops::buffer_replace

# --- search (AGENTS.md D36) ---------------------------------------------------
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

# buffer.find {needle, ?from?, ?nocase?, ?backwards?, ?wholeword?, ?buffer?} ->
#   {found 0} | {found 1, start, end, wrapped} ; the next match from `from`
# (default 1.0), wrapping around the document.
proc rio::ops::buffer_find {params} {
	set id [_bufid $params]
	set needle [_needle $params buffer.find]
	# No expr around the index: it would coerce a column like 1.10 to the
	# float 1.1 (the editor_proxy delete-arm bug, met again on the core side).
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
# Every match, first to last — a frontend's highlight-all and match count. A
# non-flat result (an array), so the wire layer registers a shape encoder (D25).
proc rio::ops::buffer_matches {params} {
	set id [_bufid $params]
	set ms [rio::doc::matches $id [_needle $params buffer.matches] \
		[_flag $params nocase] [_flag $params wholeword] [_flag $params regex]]
	return [dict create result [dict create count [llength $ms] matches $ms]]
}
rio::dispatch::register buffer.matches rio::ops::buffer_matches

# buffer.replace_all {needle, text, ?nocase?, ?wholeword?, ?buffer?} -> {count} ; replaces
# every match as ONE recorded edit — one undo step, one buffer.changed — so a
# Replace All undoes as the single action it was.
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
# The open-buffer counterpart to project.search (D51): the SAME line-grouped shape,
# but over the open buffers' live text (reflecting unsaved edits), not the on-disk
# tree — the Search panel's "Open docs" and "Current doc" scopes (D52). `only` (a
# buffer id) restricts to that one buffer (current-doc scope); absent, every open
# buffer is searched, in creation order. Matching runs core-side through the shared
# rio::doc::grep_lines, so buffer and project search can never disagree. `truncated`
# is always 0 — the open set is bounded and already in memory, so no row cap.
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

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
	set removed [rio::doc::replace $id $start $end $text]
	set ev [dict create event buffer.changed params \
		[dict create buffer $id start $start end $end text $text removed $removed]]
	return [dict create result {} events [list $ev]]
}
rio::dispatch::register buffer.replace rio::ops::buffer_replace

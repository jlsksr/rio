#!/usr/bin/env tclsh
#
# SPIKE — throwaway. Not rio. Proves the riskiest architectural bet before any
# real core code commits to it:
#
#   D1  the core is UI-less          -> NO `package require Tk` anywhere here
#   D2  transport-independent proto  -> a socket server is just one transport
#   D3  core owns the canonical doc  -> frontends never self-edit; they echo us
#   D11 wire = JSONL                 -> {id,op,params} / {id,ok,result} / {event,params}
#   D12 doc = list of lines, line.col-> range replacement is the one edit primitive
#
# It also exercises the event-loop interplay that bit us during toolchain setup:
# a headless tclsh driven entirely by `vwait` + `fileevent`, exiting cleanly on
# signal, never dropping into a Tk event loop.
#
# Run:   tclsh core.tcl [port]        (default 7711)

package require json   ;# inbound parse only; we hand-encode outbound (tiny, flat)

set ::PORT  [expr {[llength $argv] ? [lindex $argv 0] : 7711}]
set ::lines [list ""]   ;# canonical document: ordered list of line strings (D12)
set ::clients {}        ;# every attached view (D3: broadcast target)

# --- JSON out (just enough for our flat messages) ---------------------------
proc jstr {s} {
	return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]\""
}
proc send {chan json} { if {[catch {puts $chan $json; flush $chan}]} { drop $chan } }

# --- the one edit primitive: replace [start,end) with text (D12) ------------
# start/end are "line.col" (1-based line, 0-based col) — Tk text widget indices.
proc apply_replace {start end text} {
	lassign [split $start .] sl sc
	lassign [split $end   .] el ec
	set sli [expr {$sl - 1}]
	set eli [expr {$el - 1}]
	set prefix [string range [lindex $::lines $sli] 0 [expr {$sc - 1}]]
	set suffix [string range [lindex $::lines $eli] $ec end]
	set segs [split $text "\n"]
	if {[llength $segs] == 1} {
		set block [list $prefix[lindex $segs 0]$suffix]
	} else {
		set block [concat \
			[list $prefix[lindex $segs 0]] \
			[lrange $segs 1 end-1] \
			[list [lindex $segs end]$suffix]]
	}
	set ::lines [concat \
		[lrange $::lines 0 [expr {$sli - 1}]] \
		$block \
		[lrange $::lines [expr {$eli + 1}] end]]
}

proc doc_text {} { return [join $::lines "\n"] }

# --- request dispatch (D11) -------------------------------------------------
proc handle {chan line} {
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} {
		puts stderr "core: bad json: $line"
		return
	}
	set id [expr {[dict exists $msg id] ? [dict get $msg id] : ""}]
	switch -- [dict get $msg op] {
		buffer.text {
			# initial sync: hand the whole document back to a freshly attached view
			send $chan "{\"id\":[jstr $id],\"ok\":true,\"result\":{\"text\":[jstr [doc_text]]}}"
		}
		buffer.replace {
			set p [dict get $msg params]
			set s [dict get $p start]
			set e [dict get $p end]
			set t [dict get $p text]
			apply_replace $s $e $t
			send $chan "{\"id\":[jstr $id],\"ok\":true,\"result\":{}}"
			# D3: the edit is canonical only once *we* broadcast it — to ALL views,
			# the sender included. No view ever mutates itself.
			set ev "{\"event\":\"buffer.changed\",\"params\":{\"start\":[jstr $s],\"end\":[jstr $e],\"text\":[jstr $t]}}"
			foreach c $::clients { send $c $ev }
		}
		default {
			send $chan "{\"id\":[jstr $id],\"ok\":false,\"error\":\"unknown op\"}"
		}
	}
}

# --- connection plumbing: nonblocking, line-framed, event-driven ------------
proc drop {chan} {
	catch {close $chan}
	set ::clients [lsearch -all -inline -not -exact $::clients $chan]
	puts stderr "core: view gone ([llength $::clients] left)"
}
proc on_readable {chan} {
	if {[catch {gets $chan line} n]} { drop $chan; return }
	if {$n < 0} { if {[eof $chan]} { drop $chan } ; return }
	handle $chan $line
}
proc accept {chan addr port} {
	fconfigure $chan -buffering line -blocking 0 -translation lf -encoding utf-8
	lappend ::clients $chan
	fileevent $chan readable [list on_readable $chan]
	puts stderr "core: view $addr:$port attached ([llength $::clients] total)"
}

socket -server accept $::PORT
puts stderr "core: listening on $::PORT — Tk-free, pid [pid]"
vwait forever

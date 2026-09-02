#!/usr/bin/env wish
#
# Headless smoke for the DEFAULT transport (AGENTS.md D30): with no --connect, the
# GUI spawns a private core as a child and talks over its stdio pipe. The core is a
# SEPARATE process, so this is a black-box check — we verify through the channel
# (buf_text), the widget, and the bytes the child writes to disk, never by peeking at
# core internals (there are none in this process). Needs a DISPLAY (Tk), never shows
# a window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/pipe.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this
# file's own non-ASCII expectations arrive mojibake and fail against the correctly-
# decoded values the GUI produces. The same guard the rio-gui and server entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
set argv {}                          ;# no --connect ⇒ default: spawn a local core
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} { puts "PASS  $label" } else {
		puts "FAIL  $label\n        got:  $got\n        want: $want" ; incr ::fails
	}
}
proc tmpbytes {bytes} {
	set f [file tempfile path] ; fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f ; return $path
}
proc diskbytes {path} { set f [open $path rb] ; set b [::read $f] ; close $f ; return $b }
proc widget {} { ::rio_real_t get 1.0 end-1c }

# --- the transport: a spawned child core over a pipe -------------------------
# The strongest proof it's out-of-process: the core's document model isn't in THIS
# interpreter (only the wire encoder was sourced).
ok "pipe: core not embedded"      [info commands rio::doc::text] ""
ok "pipe: wire encoder present"   [expr {[info commands rio::wire::str] ne ""}] 1
ok "pipe: marked local"           $::core_remote 0
ok "pipe: channel open"           [expr {[info exists ::core_chan] && $::core_chan in [chan names]}] 1
ok "pipe: a buffer adopted"       [expr {$::cur ne "" && [llength [gorder $::focus]] == 1}] 1
ok "pipe: agent pane available"   [rio::panel::exists chat] 1

# --- open / edit / save, all over the pipe -----------------------------------
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
ok "pipe: widget mirrors file"    [widget] "alpha\nbeta\n"
ok "pipe: buffer.text over pipe"  [buf_text $::cur] "alpha\nbeta\n"
.ed.t insert 1.0 "X"
ok "pipe: edit echoed to widget"  [widget] "Xalpha\nbeta\n"
ok "pipe: edit visible over pipe" [buf_text $::cur] "Xalpha\nbeta\n"
do_save
ok "pipe: child wrote the bytes"  [diskbytes $p] "Xalpha\nbeta\n"
file delete -force $p

# --- undo/redo + compare (diff.lines) over the pipe --------------------------
do_undo
ok "pipe: undo over the pipe"     [buf_text $::cur] "alpha\nbeta\n"
do_redo
ok "pipe: redo over the pipe"     [buf_text $::cur] "Xalpha\nbeta\n"
compare_open "a\nb\nc" "a\nB\nc" "l" "r"
ok "pipe: compare opened"         $::compare_shown 1
ok "pipe: diff tagged via pipe" \
	[expr {[llength [.cmp.l.t tag ranges del]] > 0 && [llength [.cmp.r.t tag ranges add]] > 0}] 1
compare_close

# --- an agent turn end to end over the real child-process pipe (D26/D30) ------
# The full agent path black-box: the GUI sends agent.send over the pipe, the child
# core runs its built-in echo provider and broadcasts the turn back as agent.* events,
# which the chat view appends. Pump the event loop until the streamed reply lands.
proc settle {cond {ms 3000}} {
	set deadline [expr {[clock milliseconds] + $ms}]
	while {[clock milliseconds] < $deadline} { update ; if {[uplevel 1 $cond]} return }
}
chat_clear
.chat.input delete 1.0 end ; .chat.input insert end "ping"
chat_send
settle {string match {*echo: ping*} [.chat.log get 1.0 end]}
ok "pipe: agent turn streams back"  [string match {*You*ping*Agent*echo: ping*} [.chat.log get 1.0 end]] 1
ok "pipe: core recorded the turn"   [llength [dict get [rio_call agent.history {}] result messages]] 2

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

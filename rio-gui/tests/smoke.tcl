#!/usr/bin/env wish
#
# Headless smoke for rio-gui: sources the real frontend (window withdrawn) and
# drives its actions and the dumb-view proxy directly — no dialogs, no synthetic
# key events — checking that the widget, the core, and the bytes on disk all
# agree. Needs a DISPLAY (Tk), but never shows a window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/smoke.tcl

set ::env(RIO_GUI_HEADLESS) 1
set argv {}                ;# don't let the frontend treat our args as a file
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}
proc tmpbytes {bytes} {
	set f [file tempfile path]
	fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f
	return $path
}
proc diskbytes {path} {
	set f [open $path rb] ; set b [::read $f] ; close $f ; return $b
}
proc widget {} { ::rio_real_t get 1.0 end-1c }

# --- open an LF file ---------------------------------------------------------
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
ok "open: path recorded"        $::path           $p
ok "open: not modified"         $::modified       0
ok "open: core has file text"   [rio::doc::text $::cur] "alpha\nbeta\n"
ok "open: widget mirrors core"  [widget]          "alpha\nbeta\n"
ok "open: encoding detected"    [dict get $::meta encoding] utf-8

# --- edit through the dumb-view proxy, then save -----------------------------
.t insert 1.0 "X"
ok "edit: marked modified"      $::modified       1
ok "edit: core updated"         [rio::doc::text $::cur] "Xalpha\nbeta\n"
ok "edit: widget updated"       [widget]          "Xalpha\nbeta\n"
do_save
ok "save: not modified"         $::modified       0
ok "save: bytes on disk"        [diskbytes $p]    "Xalpha\nbeta\n"

# --- tricky characters survive the proxy (no %A breakage) --------------------
.t insert 1.0 "\{\"z"
ok "edit: braces/quotes intact" [string range [rio::doc::text $::cur] 0 2] "\{\"z"

# --- CRLF is preserved across open -> edit -> save ---------------------------
set q [tmpbytes "a\r\nb\r\n"]
do_open $q
ok "crlf: eol detected"         [dict get $::meta eol] crlf
.t insert 1.0 ">"
do_save
ok "crlf: preserved on save"    [diskbytes $q]    ">a\r\nb\r\n"

# --- undo / redo through the frontend ----------------------------------------
# (core text is normalized to \n; CRLF only re-appears on save, checked above)
do_undo
ok "undo: edit reverted"        [rio::doc::text $::cur] "a\nb\n"
do_redo
ok "redo: edit reapplied"       [rio::doc::text $::cur] ">a\nb\n"

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

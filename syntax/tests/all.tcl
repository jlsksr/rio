# Run the whole rio syntax-highlighter test suite:  tclsh syntax/tests/all.tcl
# Pure Tcl (the highlighters are Tk-free, D32), so this needs no display.
#
# The UTF-8 source guard every rio entry point carries (D54): Tcl 8.6 decodes a script
# with the SYSTEM encoding, cp1252 on Windows, so the file re-reads itself as UTF-8.
# No-op on a UTF-8 system. Each .test carries its own copy, for the same reason —
# tcltest runs it as a script of its own. rio-core/tests/all.tcl explains it in full.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

# Run the whole rio syntax-highlighter test suite:  tclsh syntax/tests/all.tcl
# Pure Tcl (the highlighters are Tk-free, D32), so this needs no display.
#
# The UTF-8 source guard every rio entry point carries (D54): Tcl 8.6 decodes a script
# with the SYSTEM encoding, cp1252 on Windows. No-op on a UTF-8 system. It covers this
# file only — a .test is decoded by the child tclsh that runs it, so non-ASCII
# EXPECTED values belong in \u escapes. rio-core/tests/all.tcl explains it in full.
if {[encoding system] ne "utf-8"} { encoding system utf-8 }

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

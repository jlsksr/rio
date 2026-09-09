# Run the whole rio syntax-highlighter test suite:  tclsh syntax/tests/all.tcl
# Pure Tcl (the highlighters are Tk-free, D32), so this needs no display.
#
# The UTF-8 source guard every rio entry point carries (D54), in the form
# rio-core/tests/all.tcl uses: tcltest runs each .test in its OWN interpreter, so
# -load is what carries the setting into all of them. No-op on a UTF-8 system.
if {[encoding system] ne "utf-8"} { encoding system utf-8 }

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure -load {catch {encoding system utf-8}}
::tcltest::configure {*}$argv
::tcltest::runAllTests

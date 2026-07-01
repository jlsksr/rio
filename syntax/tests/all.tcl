# Run the whole rio syntax-highlighter test suite:  tclsh syntax/tests/all.tcl
# Pure Tcl (the highlighters are Tk-free, D32), so this needs no display.
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

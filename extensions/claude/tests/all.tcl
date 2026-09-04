# Run the whole claude-plugin test suite:  tclsh extensions/claude/tests/all.tcl
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

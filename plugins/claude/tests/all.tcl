# Run the whole claude-plugin test suite:  tclsh plugins/claude/tests/all.tcl
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

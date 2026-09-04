# Run the whole openai-plugin test suite:  tclsh extensions/openai/tests/all.tcl
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

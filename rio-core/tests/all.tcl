# Run the whole rio-core test suite:  tclsh rio-core/tests/all.tcl
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

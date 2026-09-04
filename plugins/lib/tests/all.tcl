# Run the whole shared-plugin-lib test suite:  tclsh plugins/lib/tests/all.tcl
package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

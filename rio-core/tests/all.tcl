# Run the whole rio-core test suite:  tclsh rio-core/tests/all.tcl
#
# Same UTF-8 source guard the rio-gui and server entry points carry: Tcl 8.6 decodes
# scripts with the SYSTEM encoding (cp1252 on Windows), so a .test file's non-ASCII
# EXPECTED values arrive mojibake and fail against a correctly-decoded result.
# tcltest runs each .test in its OWN interpreter, so setting it here is not enough —
# -load carries it into every one. No-op where the system encoding is already UTF-8.
if {[encoding system] ne "utf-8"} { encoding system utf-8 }

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure -load {catch {encoding system utf-8}}
::tcltest::configure {*}$argv
::tcltest::runAllTests

# Run the whole rio-core test suite:  tclsh rio-core/tests/all.tcl
#
# Same UTF-8 source guard the rio-gui and server entry points carry (D54): Tcl 8.6
# decodes a script with the SYSTEM encoding, cp1252 on Windows. No-op on a UTF-8 host.
#
# It protects THIS file and nothing else, and that limit is worth knowing. tcltest runs
# each .test in a child tclsh, which decodes that file at its own startup — before any
# option set here could apply. This file used to also pass `-load {encoding system
# utf-8}` claiming that carried the setting into every test file; it does not. A -load
# script is run by ::tcltest::loadTestedCommands, which no rio .test calls, so it never
# ran at all (measured on Windows: the encoding inside a test file was still cp1252).
#
# The rule that does work: a .test with non-ASCII EXPECTED values writes them as \u
# escapes, never as literals, or it compares a correctly-decoded result against its own
# mojibake. rio-core/tests/http.test is the one file where that bites. See WINDOWS.md §8.
if {[encoding system] ne "utf-8"} { encoding system utf-8 }

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

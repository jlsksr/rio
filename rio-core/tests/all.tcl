# Run the whole rio-core test suite:  tclsh rio-core/tests/all.tcl
#
# The UTF-8 source guard every rio entry point carries (D54): Tcl 8.6 decodes a script
# with the SYSTEM encoding, cp1252 on Windows, so the file re-reads itself as UTF-8.
# No-op on a UTF-8 host, and on Tcl 9 everywhere.
#
# It protects THIS file and nothing else, which is why every .test carries its own copy.
# tcltest runs each one in a child tclsh, and nothing the parent configures reaches that
# child: this file used to also pass `-load {encoding system utf-8}` claiming it did, and
# it does not — a -load script runs from ::tcltest::loadTestedCommands, which no rio .test
# calls, so it never ran at all (measured on Windows: cp1252 inside the test file still).
# A .test is a script run by tclsh, though, so the guard works there exactly as it does
# here, and `encoding.test` holds every runnable script to it.
#
# Reproducing the failure needs no Windows box: `LANG=C LC_ALL=C tclsh` gives
# `encoding system` = iso8859-1 on Linux, which mangles a UTF-8 literal the same way.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

package require tcltest
::tcltest::configure -testdir [file dirname [info script]]
::tcltest::configure {*}$argv
::tcltest::runAllTests

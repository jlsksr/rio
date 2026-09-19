# rio-core -- the hard-dependency gate (AGENTS.md D116).
#
# rio has three dependencies (Tcl/Tk, tcllib, tcltls) and INSTALL.md section 1 names
# them, but a missing one used to arrive as a Tcl STACK TRACE from a bare
# `package require json` at an entry point. That is a bad first minute on any host,
# and on Windows it is worse than untidy: wish.exe turns an uncaught startup error
# into a MODAL DIALOG that blocks until someone clicks it, with the trace inside
# (RELEASING.md). The one dependency that already behaved -- tcltls -- is the model:
# rio::tls::ensure defers it and reports what is missing in a sentence.
#
# So: one table, one message, sourced first at every entry point. It says what is
# missing, which OS package carries it, and where the full table lives. `message`
# is PURE so a test can read the text without a process having to die for it.
#
# Not a general-purpose loader: `require` EXITS. It is for the handful of packages
# rio cannot run at all without, called before anything else has started. Anything
# optional (tkdnd, D86) stays a plain `catch {package require ...}` at its own site,
# and anything deferred (tls) stays with the code that needs it.
#
# THIS FILE IS DELIBERATELY PURE ASCII, comments included. It is sourced by the entry
# points ABOVE their D54 encoding guard -- it has to be, since it gates the very
# `package require` that guard's file would otherwise die on -- so its own literals
# are decoded with the SYSTEM encoding, cp1252 on Windows. An em dash here would
# reach the user mojibake in the one message they must be able to read.
#
# No Tk (the core is Tk-free, D1); the Tk-flavoured variant is gui_require below,
# which the GUI entry point alone calls, once Tk is known to be up.

namespace eval rio::deps {
	# package -> what provides it, in INSTALL.md section 1's words
	variable provides {
		json         "tcllib (apt/pkg_add: tcllib, Alpine: tcl-lib)"
		json::write  "tcllib (apt/pkg_add: tcllib, Alpine: tcl-lib)"
		md5          "tcllib (apt/pkg_add: tcllib, Alpine: tcl-lib)"
		sha256       "tcllib (apt/pkg_add: tcllib, Alpine: tcl-lib)"
		Tk           "Tk (apt: tk, OpenBSD: tk%8.6)"
		tls          "tcltls (apt: tcl-tls, apk/pkg_add: tcltls)"
	}
}

# What to tell someone whose host is missing `pkg`. Two lines and a pointer: the
# package name they typed is rarely the package name they must install, which is the
# whole reason a trace is useless here.
proc rio::deps::message {pkg} {
	variable provides
	set who [expr {[dict exists $provides $pkg] ? [dict get $provides $pkg] : "your Tcl distribution"}]
	# Joined, not one continued string: a backslash-newline in Tcl collapses to a
	# SPACE, which would leave trailing whitespace at every line break.
	return [join [list \
		"rio needs the Tcl package `$pkg`, which isn't installed on this host." \
		"" \
		"Install $who, then start rio again." \
		"The full dependency table is in INSTALL.md section 1."] "\n"]
}

# Load `pkg` or stop with that message. stderr + exit 1 -- no trace, because there is
# nothing in a trace for the person who has to install a package.
proc rio::deps::require {pkg} {
	if {[catch {uplevel #0 [list package require $pkg]}]} {
		puts stderr [message $pkg]
		exit 1
	}
}

# The same, for an entry point that already has Tk up: also put it in a message box.
# Under wish on Windows there is no console for stderr to land in, so a stderr-only
# report is a silent death there -- the very platform this matters most on.
proc rio::deps::gui_require {pkg} {
	if {[catch {uplevel #0 [list package require $pkg]}]} {
		set m [message $pkg]
		puts stderr $m
		catch {wm withdraw .}
		catch {tk_messageBox -icon error -type ok -title "rio - missing dependency" -message $m}
		exit 1
	}
}

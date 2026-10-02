# rio-core -- the hard-dependency gate (D116).
#
# A missing dependency must not arrive as a stack trace. Every entry point
# sources this first. It says what is missing, which OS package carries it,
# and where the full table is (INSTALL.md section 1).
#
# - `require` exits. It is for packages rio cannot run without. An optional
#   one (tkdnd, D86) stays a `catch {package require ...}` where it is used;
#   tls is loaded by the code that needs it.
# - `message` has no side effect, so a test can read the text.
# - THIS FILE IS PURE ASCII, comments included. It is sourced above the D54
#   encoding guard, so on Windows its literals are read as cp1252.
# - No Tk here. gui_require is for the GUI entry point, once Tk is up.

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

# What to tell a user whose host lacks `pkg`: the OS package to install.
proc rio::deps::message {pkg} {
	variable provides
	set who [expr {[dict exists $provides $pkg] ? [dict get $provides $pkg] : "your Tcl distribution"}]
	# Joined: a backslash-newline in a string would become a space.
	return [join [list \
		"rio needs the Tcl package `$pkg`, which isn't installed on this host." \
		"" \
		"Install $who, then start rio again." \
		"The full dependency table is in INSTALL.md section 1."] "\n"]
}

# Load `pkg`, or print that message to stderr and exit 1.
proc rio::deps::require {pkg} {
	if {[catch {uplevel #0 [list package require $pkg]}]} {
		puts stderr [message $pkg]
		exit 1
	}
}

# The same with a message box, for an entry point that has Tk up. Under wish
# on Windows stderr goes nowhere.
proc rio::deps::gui_require {pkg} {
	if {[catch {uplevel #0 [list package require $pkg]}]} {
		set m [message $pkg]
		puts stderr $m
		catch {wm withdraw .}
		catch {tk_messageBox -icon error -type ok -title "rio - missing dependency" -message $m}
		exit 1
	}
}

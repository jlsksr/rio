# rio-core — the one place rio decides how an https connection is verified (AGENTS.md D109).
#
# Two callers share it: the extension-repository fetch (rio::http, D39) and the LLM
# providers' transport (rio::llm::http, plugins/lib, D8). Before D109 the transport kept
# a private copy that only knew Unix CA-bundle paths, so on Windows it asked tcltls to
# require a valid certificate while giving it nothing to validate against.
#
# TRUST COMES FROM THE HOST, never from rio. The first CA source that applies:
#   1. SSL_CERT_FILE / SSL_CERT_DIR in the core's environment — OpenSSL's own override,
#      the conventional way to trust a private CA. Passed explicitly as -cafile/-cadir
#      rather than left for the library to find, so it means the same thing on every
#      tcltls and on LibreSSL.
#   2. The system bundle the package manager maintains: Debian/Alpine, RHEL-family, then
#      OpenBSD (also macOS).
#   3. On Windows, the Windows certificate store itself — tcltls 1.8 on OpenSSL 3.2+
#      reaches it as a -castore URI.
#   4. Nothing found: pass no CA at all and STILL require verification, so the handshake
#      fails closed and `explain` says what to set. Never a silent downgrade to unverified.
# rio ships no CA bundle of its own: one would go stale, ignore the roots an admin
# installed, and make rio a certificate distributor.
#
# HOST NAMES. A trusted chain proves only that some CA vouched for some name; the check
# that the name is the server's own is what tcltls 1.8 added (-servername → SSL_add1_host,
# verified against 1.8.0: a trusted certificate for another name fails "hostname
# mismatch"). tcltls 1.7 sends the name for SNI and never compares it. `checks_hostname`
# reports which one this core has; callers decide what to do with a 1.7.
#
# tcltls is loaded LAZILY, by `ensure`, on the first https connection — a core without it
# serves plain-http repositories exactly as before. Tk-free (D1); standalone (sourced by
# plugins/lib/transport.tcl when the core has not loaded it, e.g. in that suite).

if {[llength [info commands rio::tls::socket]]} { return }

namespace eval rio::tls {
	variable ready 0
	# The system bundles, in the order tried. A variable so a test can point it elsewhere.
	variable bundles {
		/etc/ssl/certs/ca-certificates.crt
		/etc/pki/tls/certs/ca-bundle.crt
		/etc/ssl/cert.pem
	}
	variable winstore org.openssl.winstore://
	# The reasons tcltls gave for the most recent failed handshake. The http package
	# reports every one of them as "failed to use socket"; `explain` puts them back.
	variable last_reasons {}
}

# Load tcltls and route https:// through `socket`, once. Raises "can't find package tls"
# when it is not installed — callers turn that into advice naming the package.
proc rio::tls::ensure {} {
	variable ready
	if {$ready} return
	package require http
	package require tls
	::http::register https 443 rio::tls::socket
	set ready 1
}

proc rio::tls::socket {args} {
	return [::tls::socket {*}[socket_opts] {*}$args]
}

# The full option list for a client socket, on this host, with this tcltls.
proc rio::tls::socket_opts {} {
	set opts [list -autoservername 1 -request 1 -require 1]
	# 1.8 moved certificate verdicts out of -command, so a -command that returns nothing
	# is harmless there — and on a 1.7, where -command still answers "verify", it would
	# not be. The reasons are a 1.8 nicety; the verification itself is not.
	if {[checks_hostname]} { lappend opts -command rio::tls::_note }
	lappend opts {*}[ca_opts $::tcl_platform(platform) [array get ::env] \
		[package present tls] [::tls::version]]
	return $opts
}

# Where to find the CA certificates — a pure function of what it is given (plus
# `file exists` on the bundle list), so every branch is testable on any host.
#   platform — $tcl_platform(platform); env — a flat {name value ...} list;
#   tlsver — tcltls's version; sslver — [tls::version], e.g. "OpenSSL 3.4.1 11 Feb 2025"
proc rio::tls::ca_opts {platform env tlsver sslver} {
	variable bundles
	variable winstore
	set opts {}
	foreach {name opt} {SSL_CERT_FILE -cafile SSL_CERT_DIR -cadir} {
		if {[dict exists $env $name] && [dict get $env $name] ne ""} {
			lappend opts $opt [dict get $env $name]
		}
	}
	if {[llength $opts]} { return $opts }
	foreach ca $bundles {
		if {[file exists $ca]} { return [list -cafile $ca] }
	}
	if {$platform eq "windows" && [package vsatisfies $tlsver 1.8-]
			&& [regexp {^OpenSSL (\d+)\.(\d+)} $sslver -> major minor]
			&& ($major > 3 || ($major == 3 && $minor >= 2))} {
		return [list -castore $winstore]
	}
	return {}
}

# Does this core's tcltls compare a certificate's name with the host it dialled?
proc rio::tls::checks_hostname {} {
	return [package vsatisfies [package present tls] 1.8-]
}

# -command callback: keep the handshake's error reasons; everything else is ignored.
proc rio::tls::_note {what chan args} {
	variable last_reasons
	switch -- $what {
		error {
			if {[lindex $args 0] ni $last_reasons} { lappend last_reasons [lindex $args 0] }
		}
		info {
			# A handshake that completes clears the reasons a previous one left behind.
			lassign $args major minor
			if {$major eq "handshake" && $minor eq "done"} { set last_reasons {} }
		}
	}
	return
}

# Turn http's "failed to use socket" into the reason the certificate was refused, and
# name the fix when there is one. Consumes the recorded reasons. `err` is returned
# unchanged when no handshake failure was recorded.
proc rio::tls::explain {err} {
	variable last_reasons
	if {![llength $last_reasons]} { return $err }
	set why [join $last_reasons "; "]
	set last_reasons {}
	set msg "$err — the server's certificate was refused ($why)"
	if {[regexp -nocase {local issuer|self-signed|unable to get} $why]} {
		append msg ". To trust a private CA, set SSL_CERT_FILE on the core's host to its PEM bundle and restart the core"
	}
	return $msg
}

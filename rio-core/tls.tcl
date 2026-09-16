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
# reports which one this core has; callers decide what to do with a 1.7 — a repository
# fetch refuses outright (rio::http), the agent refuses unless the user allowed it
# (plugins/lib/transport.tcl, D110).
#
# EXCEPTIONS — a certificate the user accepted though it does not verify (D111). The
# browser model: refuse by default, show why (`inspect`, a handshake that sends nothing),
# and let the user accept THAT EXACT certificate for THAT host:port. An exception is the
# leaf's SHA-256 fingerprint, kept in $XDG_CONFIG_HOME/rio/certificates.conf (D21 format,
# parsed, never executed, read afresh each time it is needed). It covers every way that
# one certificate fails — an untrusted issuer, expiry, another name — and nothing else:
#   - a certificate that verifies never consults exceptions;
#   - a different certificate on the same host:port is refused, and said to have changed;
#   - a pin on one port says nothing about another.
# It lives here, not in the repository code, because a pin is a statement about a server's
# certificate, not about which feature dials it: every https connection the core makes
# honours it. Only tcltls 1.8 can do this (-validatecommand is new there); on 1.7 nothing
# changes.
#
# How `_verify` judges a chain (established against tcltls 1.8.0 / OpenSSL 3.4, by probe):
# OpenSSL calls it once or more per certificate, top of the chain first, and ALWAYS ends
# with a depth-0 call for the leaf. So a failure higher up passes provisionally — only if
# the host has an exception at all — and the verdict is given at depth 0, where the leaf's
# fingerprint is known. A callback that errors fails the handshake (also probed).
#
# tcltls is loaded LAZILY, by `ensure`, on the first https connection — a core without it
# serves plain-http repositories exactly as before. Tk-free (D1); standalone (sourced by
# plugins/lib/transport.tcl when the core has not loaded it, e.g. in that suite).

if {[llength [info commands rio::tls::socket]]} { return }

namespace eval rio::tls {
	variable ready 0
	variable override_path ""   ;# tests pin certificates.conf here
	variable seq 0              ;# one token per connection, for _verify's per-chain state
	variable chains {}          ;# token -> {failed 0|1 reasons {…}}, trimmed as it grows
	variable refused {}         ;# host:port -> {reasons {…} changed 0|1}, the last refusal
	variable probes {}          ;# probe token -> what inspect has seen so far
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

# http calls this as `rio::tls::socket ?opts? host port` — the peer is the last two words.
proc rio::tls::socket {args} {
	return [::tls::socket {*}[socket_opts [lindex $args end-1] [lindex $args end]] {*}$args]
}

# The full option list for a client socket to host:port, on this host, with this tcltls.
# Without a host (a caller that only wants to see the policy) there is no exception check.
proc rio::tls::socket_opts {{host ""} {port ""}} {
	set opts [_base_opts]
	# 1.8 moved certificate verdicts out of -command, so a -command that returns nothing
	# is harmless there — and on a 1.7, where -command still answers "verify", it would
	# not be. The reasons are a 1.8 nicety; the verification itself is not.
	if {[checks_hostname]} {
		lappend opts -command rio::tls::_note
		if {$host ne ""} {
			lappend opts -validatecommand [list rio::tls::_verify [origin $host $port] [_token]]
		}
	}
	return $opts
}

# What every client socket starts from: the name it dialled sent and checked, verification
# required, against the host's CA store.
proc rio::tls::_base_opts {} {
	return [list -autoservername 1 {*}[_verify_opts]]
}

# The same without -autoservername, for a channel `inspect` stacks TLS onto itself (it
# passes -servername explicitly; -autoservername is tls::socket's alone).
proc rio::tls::_verify_opts {} {
	return [list -request 1 -require 1 {*}[ca_opts $::tcl_platform(platform) \
		[array get ::env] [package present tls] [::tls::version]]]
}

# The name an exception is filed under: lower-case host (IPv6 without brackets), colon, port.
proc rio::tls::origin {host port} {
	return "[string tolower [string trim $host {[]}]]:$port"
}

# host:port of an https URL (port 443 unless given), or "" for anything else.
proc rio::tls::origin_of {url} {
	if {![regexp -nocase {^https://(\[[^\]/]*\]|[^/?#:]*)(?::(\d+))?(?:[/?#]|$)} $url -> host port]} {
		return ""
	}
	if {$host eq "" || $host eq {[]}} { return "" }
	if {$port eq ""} { set port 443 }
	return [origin $host $port]
}

# A fresh token. The per-chain state it keys is small, but a long-running core makes many
# connections, so anything more than 64 tokens old is dropped here.
proc rio::tls::_token {} {
	variable seq
	variable chains
	incr seq
	foreach t [dict keys $chains] {
		if {$t < $seq - 64} { dict unset chains $t }
	}
	return $seq
}

# -validatecommand for every client connection on 1.8: OpenSSL's verdict stands, except
# that a failing chain passes when its leaf is the certificate the user accepted for this
# origin (the header explains the order it relies on). Any fault inside refuses.
proc rio::tls::_verify {origin token what args} {
	if {$what ne "verify"} { return 1 }
	if {[catch {_judge $origin $token {*}$args} verdict]} { return 0 }
	return $verdict
}

proc rio::tls::_judge {origin token chan depth cert status err} {
	variable chains
	variable refused
	if {![dict exists $chains $token]} { dict set chains $token [dict create failed 0 reasons {}] }
	if {!$status} {
		dict set chains $token failed 1
		if {$err ni [dict get $chains $token reasons]} { dict lappend chains $token reasons $err }
	}
	if {![dict get $chains $token failed]} { return 1 }
	set pin [exception_get $origin]
	set changed 0
	if {$depth > 0} {
		set ok [expr {$pin ne ""}]
	} else {
		set ok [expr {$pin ne "" && [string tolower [dict get $cert sha256_hash]] eq $pin}]
		set changed [expr {$pin ne "" && !$ok}]
	}
	if {!$ok} {
		dict set refused $origin [dict create \
			reasons [dict get $chains $token reasons] changed $changed]
	}
	return $ok
}

# The last certificate refusal recorded for an origin, consumed; "" when there was none.
# rio::http asks after a failed https fetch, to tell "the certificate was refused" (which
# the user can do something about) from every other way a connection fails.
proc rio::tls::take_refusal {origin} {
	variable refused
	if {![dict exists $refused $origin]} { return "" }
	set r [dict get $refused $origin]
	dict unset refused $origin
	return $r
}

# --- exceptions: certificates.conf ------------------------------------------------------

proc rio::tls::exceptions_path {} {
	variable override_path
	if {$override_path ne ""} { return $override_path }
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio certificates.conf]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio certificates.conf]
	}
	return ""
}

# A fingerprint as stored and compared: 64 lower-case hex digits, colons and spaces
# dropped. "" when it isn't one.
proc rio::tls::fingerprint_norm {s} {
	set h [string tolower [string map {: "" " " ""} [string trim $s]]]
	if {![regexp {^[0-9a-f]{64}$} $h]} { return "" }
	return $h
}

# The same fingerprint the way browsers and `openssl x509 -fingerprint` show it.
proc rio::tls::fingerprint_show {s} {
	set h [string toupper [fingerprint_norm $s]]
	return [join [regexp -all -inline .. $h] :]
}

# Every exception: origin -> {sha256 <normalized> subject <s> accepted <date>}. A missing,
# unreadable or malformed file is no exceptions at all, and so is an entry without a valid
# fingerprint — every way the file can be wrong falls to the refusing side. Without the
# conf parser (tls.tcl sourced standalone) there are none either.
proc rio::tls::exceptions {} {
	set p [exceptions_path]
	if {$p eq "" || ![file isfile $p] || ![llength [info commands ::rio::conf::read_file]]} {
		return [dict create]
	}
	if {[catch {::rio::conf::read_file $p} conf]} { return [dict create] }
	set out [dict create]
	dict for {sect kv} $conf {
		if {![regexp {^.+:\d+$} $sect]} continue
		if {![dict exists $kv sha256]} continue
		set h [fingerprint_norm [dict get $kv sha256]]
		if {$h eq ""} continue
		set e [dict create sha256 $h subject "" accepted ""]
		foreach k {subject accepted} {
			if {[dict exists $kv $k]} { dict set e $k [dict get $kv $k] }
		}
		dict set out [string tolower $sect] $e
	}
	return $out
}

proc rio::tls::exception_get {origin} {
	set all [exceptions]
	if {![dict exists $all $origin]} { return "" }
	return [dict get $all $origin sha256]
}

# Accept `sha256` for origin (replacing any earlier one). Returns the file written, or ""
# when there is nowhere to write. Raises on a malformed fingerprint.
proc rio::tls::exception_add {origin sha256 {subject ""}} {
	set h [fingerprint_norm $sha256]
	if {$h eq ""} { error "not a SHA-256 fingerprint: $sha256" }
	set all [exceptions]
	dict set all $origin [dict create sha256 $h \
		subject [string map {"\n" " " "\r" " "} $subject] \
		accepted [clock format [clock seconds] -format %Y-%m-%d]]
	return [_exceptions_write $all]
}

# Forget origin's exception. Returns 1 if there was one.
proc rio::tls::exception_remove {origin} {
	set all [exceptions]
	if {![dict exists $all $origin]} { return 0 }
	dict unset all $origin
	_exceptions_write $all
	return 1
}

proc rio::tls::_exceptions_write {all} {
	set p [exceptions_path]
	if {$p eq ""} { return "" }
	file mkdir [file dirname $p]
	set fh [open $p w]
	fconfigure $fh -encoding utf-8
	puts $fh "# rio — certificates you accepted although they did not verify (AGENTS.md D111)."
	puts $fh "# One section per host:port; rio trusts exactly the certificate with this SHA-256"
	puts $fh "# fingerprint there, and asks again if the server's certificate changes."
	puts $fh "# Delete a section to take an exception back."
	foreach o [lsort [dict keys $all]] {
		set e [dict get $all $o]
		puts $fh ""
		puts $fh "\[$o\]"
		puts $fh "sha256 = [fingerprint_show [dict get $e sha256]]"
		if {[dict get $e subject] ne ""} { puts $fh "subject = [dict get $e subject]" }
		if {[dict get $e accepted] ne ""} { puts $fh "accepted = [dict get $e accepted]" }
	}
	close $fh
	return $p
}

# --- inspect: what a server's certificate is, and what is wrong with it ----------------

# Handshake with host:port and report its certificate, sending nothing after the handshake:
#   {host port subject issuer names not_before not_after sha256 problems reasons accepted}
# `problems` are classes the user can read — untrusted, expired, not_yet_valid,
# name_mismatch, other — plus `changed` when an exception exists for a different
# certificate; `reasons` are OpenSSL's own words. An empty `problems` means it verifies.
# Raises when the handshake cannot happen (unreachable, not TLS, timeout). Needs 1.8:
# the caller checks `checks_hostname` first.
#
# Re-entrancy: like rio::http::get it waits in the event loop; it touches no document state.
proc rio::tls::inspect {host port {timeout_ms 10000}} {
	variable probes
	ensure
	set id [_token]
	dict set probes $id [dict create reasons {} leaf {} state ""]
	# A plain TCP connect first, TLS stacked on after: a tcltls socket opened -async never
	# reports a refused connection (probed), so the probe would sit out its whole timeout.
	set host [string trim $host {[]}]
	if {[catch {::socket -async $host $port} s]} {
		dict unset probes $id
		error $s
	}
	fconfigure $s -blocking 0
	set timer [after $timeout_ms [list rio::tls::_probe_end $s $id [list error "timed out"]]]
	fileevent $s writable [list rio::tls::_probe_connected $s $id $host]
	while {[dict get $probes $id state] eq ""} {
		vwait ::rio::tls::probes
	}
	after cancel $timer
	catch {close $s}
	set p [dict get $probes $id]
	dict unset probes $id
	lassign [dict get $p state] how why
	if {$how ne "ok"} { error $why }
	set leaf [dict get $p leaf]
	if {$leaf eq ""} { error "the server presented no certificate" }

	set problems {}
	foreach r [dict get $p reasons] {
		switch -regexp -- $r {
			{(?i)expired}           { set c expired }
			{(?i)not yet valid}     { set c not_yet_valid }
			{(?i)hostname mismatch} { set c name_mismatch }
			{(?i)self.signed|issuer|verify the first|untrusted} { set c untrusted }
			default                 { set c other }
		}
		if {$c ni $problems} { lappend problems $c }
	}
	set sha [string tolower [dict get $leaf sha256_hash]]
	set pin [exception_get [origin $host $port]]
	if {$pin ne "" && $pin ne $sha && [llength $problems]} { lappend problems changed }
	set names {}
	if {[dict exists $leaf subjectAltName]} {
		foreach n [dict get $leaf subjectAltName] {
			regsub {^DNS:} $n "" n
			lappend names $n
		}
	}
	return [dict create host [string trim $host {[]}] port $port \
		subject [dict get $leaf subject] issuer [dict get $leaf issuer] names $names \
		not_before [_date [dict get $leaf notBefore]] not_after [_date [dict get $leaf notAfter]] \
		sha256 [fingerprint_show $sha] problems $problems reasons [dict get $p reasons] \
		accepted [expr {$pin ne "" && $pin eq $sha}]]
}

# The probe's -validatecommand: accept everything, so the handshake completes and every
# problem is seen, and keep the leaf (the last depth-0 call) and every failure's reason.
proc rio::tls::_probe {id what args} {
	variable probes
	if {$what ne "verify" || ![dict exists $probes $id]} { return 1 }
	lassign $args chan depth cert status err
	if {!$status} {
		set rs [dict get $probes $id reasons]
		if {$err ni $rs} { dict set probes $id reasons [linsert $rs end $err] }
	}
	if {$depth == 0} { dict set probes $id leaf $cert }
	return 1
}

proc rio::tls::_probe_connected {s id host} {
	fileevent $s writable {}
	set err [fconfigure $s -error]
	if {$err ne ""} {
		_probe_end $s $id [list error $err]
		return
	}
	if {[catch {
		::tls::import $s {*}[_verify_opts] -servername $host \
			-validatecommand [list rio::tls::_probe $id]
	} e]} {
		_probe_end $s $id [list error $e]
		return
	}
	fileevent $s readable [list rio::tls::_probe_step $s $id]
	_probe_step $s $id
}

proc rio::tls::_probe_step {s id} {
	if {[catch {::tls::handshake $s} done]} {
		_probe_end $s $id [list error $done]
	} elseif {$done} {
		_probe_end $s $id [list ok ""]
	}
}

proc rio::tls::_probe_end {s id state} {
	variable probes
	if {![dict exists $probes $id] || [dict get $probes $id state] ne ""} return
	catch {fileevent $s readable {}}
	catch {fileevent $s writable {}}
	dict set probes $id state $state
}

# OpenSSL's "Feb  1 00:00:00 2020 GMT" as "2020-02-01 00:00 UTC"; unparseable stays as is.
proc rio::tls::_date {s} {
	set t [regsub -all {\s+} [string trim $s] " "]
	if {[catch {clock scan $t -format "%b %d %H:%M:%S %Y GMT" -gmt 1} secs]} { return $s }
	return [clock format $secs -format "%Y-%m-%d %H:%M UTC" -gmt 1]
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
			# "no digest set" is OpenSSL's echo of _verify refusing — noise beside the reason.
			if {[string match "*no digest set*" [lindex $args 0]]} return
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
		# SSL_CERT_FILE replaces the system bundle rather than adding to it, so a file holding
		# only the private CA would cut off every public server, the agent's provider included.
		append msg ". To trust a private CA, add it to the core host's certificate store (update-ca-certificates, trust anchor); or set SSL_CERT_FILE to a PEM bundle holding it and the public CAs, and restart the core"
	}
	return $msg
}


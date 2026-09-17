# rio-core — the tls.* op namespace: certificates the user accepts (AGENTS.md D111), and the
# core-wide https setting (D114).
#
# A certificate that does not verify is refused (rio::tls). These ops are the browser's
# "Advanced…" path, for a client to offer: look at the certificate and what is wrong with
# it, accept that exact certificate for its host:port, list what was accepted, take an
# acceptance back. The file behind them is $XDG_CONFIG_HOME/rio/certificates.conf on the
# CORE's host — the certificate in question is the one the core sees on its network (D30).
#
# Trust posture: like repo.fetch, as open as the channel it arrives on (D30).
#
#   tls.inspect  {url ?timeout?}       -> {host port subject issuer names not_before
#                                          not_after sha256 problems reasons accepted}
#   tls.accept   {host port sha256 ?subject?} -> {host port sha256}
#   tls.accepted {}                    -> {exceptions [{host port sha256 subject accepted}]}
#   tls.forget   {host port}           -> {removed 0|1}
#   tls.settings {}                    -> {unchecked checks_hostname tcltls}
#   tls.settings.set {unchecked}       -> {unchecked}
#
# tls.accept takes the fingerprint the user was SHOWN, never "whatever the server presents
# now": fetching it afresh at accept time would let a server swap certificates between the
# review and the click.

proc rio::ops::_tls_host_port {params op} {
	foreach k {host port} {
		if {![dict exists $params $k]} { rio::error::raise bad_request "$op requires $k" }
	}
	set host [string trim [dict get $params host] {[]}]
	set port [dict get $params port]
	if {$host eq "" || [regexp {[\s/\[\]]} $host]} {
		rio::error::raise bad_request "$op: not a host name: [dict get $params host]"
	}
	if {![string is integer -strict $port] || $port < 1 || $port > 65535} {
		rio::error::raise bad_request "$op: not a port: $port"
	}
	return [list $host $port]
}

proc rio::ops::tls_inspect {params} {
	if {![dict exists $params url]} { rio::error::raise bad_request "tls.inspect requires url" }
	set url [dict get $params url]
	set origin [rio::tls::origin_of $url]
	if {$origin eq ""} {
		rio::error::raise bad_request "tls.inspect takes an https:// url, got: $url"
	}
	set timeout [expr {[dict exists $params timeout] ? [dict get $params timeout] : 10000}]
	if {![string is integer -strict $timeout] || $timeout <= 0} {
		rio::error::raise bad_request "tls.inspect timeout must be a positive integer (ms)"
	}
	if {[catch {rio::tls::ensure} e]} {
		rio::error::raise io_error "https needs tcltls on the core's host: $e"
	}
	if {![rio::tls::checks_hostname]} {
		rio::error::raise io_error "reviewing a certificate needs tcltls 1.8 or newer on the core's host — this core has tcltls [package present tls]"
	}
	set i [string last : $origin]
	set host [string range $origin 0 [expr {$i - 1}]]
	set port [string range $origin [expr {$i + 1}] end]
	if {[catch {rio::tls::inspect $host $port $timeout} r]} {
		rio::error::raise io_error "couldn't get the certificate of $origin: $r"
	}
	return [dict create result $r]
}
rio::dispatch::register tls.inspect rio::ops::tls_inspect

proc rio::ops::tls_accept {params} {
	lassign [_tls_host_port $params tls.accept] host port
	if {![dict exists $params sha256]} { rio::error::raise bad_request "tls.accept requires sha256" }
	set h [rio::tls::fingerprint_norm [dict get $params sha256]]
	if {$h eq ""} {
		rio::error::raise bad_request "tls.accept: sha256 must be a SHA-256 fingerprint (64 hex digits)"
	}
	set subject [expr {[dict exists $params subject] ? [dict get $params subject] : ""}]
	rio::tls::exception_add [rio::tls::origin $host $port] $h $subject
	return [dict create result [dict create host [string tolower $host] port $port \
		sha256 [rio::tls::fingerprint_show $h]]]
}
rio::dispatch::register tls.accept rio::ops::tls_accept

proc rio::ops::tls_accepted {params} {
	set items {}
	dict for {origin e} [rio::tls::exceptions] {
		set i [string last : $origin]
		lappend items [dict create host [string range $origin 0 [expr {$i - 1}]] \
			port [string range $origin [expr {$i + 1}] end] \
			sha256 [rio::tls::fingerprint_show [dict get $e sha256]] \
			subject [dict get $e subject] accepted [dict get $e accepted]]
	}
	return [dict create result [dict create exceptions $items]]
}
rio::dispatch::register tls.accepted rio::ops::tls_accepted

proc rio::ops::tls_forget {params} {
	lassign [_tls_host_port $params tls.forget] host port
	return [dict create result [dict create \
		removed [rio::tls::exception_remove [rio::tls::origin $host $port]]]]
}
rio::dispatch::register tls.forget rio::ops::tls_forget

# The core-wide switch (D114): may https go ahead on a tcltls that cannot check host names?
# `checks_hostname` and `tcltls` (the version, "" without one) let a client say whether the
# switch matters on THIS core — on 1.8+ it changes nothing. Stored in the core's tls.conf:
# the tcltls in question is the core's, so the choice is too, for every frontend attached.
proc rio::ops::tls_settings {params} {
	set v [rio::tls::present]
	return [dict create result [dict create unchecked [rio::tls::unchecked_ok] \
		checks_hostname [expr {$v ne "" && [rio::tls::checks_hostname]}] tcltls $v]]
}
rio::dispatch::register tls.settings rio::ops::tls_settings

proc rio::ops::tls_settings_set {params} {
	if {![dict exists $params unchecked]} {
		rio::error::raise bad_request "tls.settings.set requires unchecked"
	}
	set v [dict get $params unchecked]
	if {![string is boolean -strict $v]} {
		rio::error::raise bad_request "tls.settings.set: unchecked must be 0 or 1, got: $v"
	}
	if {[catch {rio::tls::set_unchecked $v} on]} {
		rio::error::raise io_error "couldn't store the https setting: $on"
	}
	return [dict create result [dict create unchecked $on]]
}
rio::dispatch::register tls.settings.set rio::ops::tls_settings_set

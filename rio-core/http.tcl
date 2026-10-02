# rio-core — a bounded HTTP GET, http:// or https:// (D39, D109).
#
# The fetch behind extension repositories (repo.fetch). In the core, so the
# GUI has no network code and a remote core fetches from its own network.
#
#   rio::http::get url ?timeout_ms? ?want_sha256?
#       -> {status <ncode> url <final-url> text <body> ?sha256 <hex>?}
#
# - http needs only Tcl. https loads tcltls on first use (rio::tls) and needs
#   1.8+, or the user's switch (D109, D114). Never quietly unverified.
# - Redirects: at most 5. https -> http is refused; http -> https is followed.
# - The body is capped at 2 MB.
# - A completed exchange is data, whatever the status: a 404 is an answer.
#   No answer (connection, timeout, size cap, redirect loop) is io_error.
#   A certificate rio::tls refused is untrusted_cert (D111).
# - ::http::geturl runs the event loop while it waits, so other requests may
#   arrive mid-fetch. Safe here: a fetch touches no document. An op that
#   changes documents must mind that window before calling this.

package require http

# tcllib's sha256, through the dependency gate (D116), for signed
# repositories (D118). Sourced here because a test sources this file alone.
source [file join [file dirname [info script]] deps.tcl]
rio::deps::require sha256

namespace eval rio::http {
	variable maxbody [expr {2 * 1024 * 1024}]  ;# body cap in bytes
	variable maxhops 5                          ;# redirects followed
}

# The -progress callback enforcing the body cap: reset aborts the transfer and
# stamps the token's status with our reason.
proc rio::http::_progress {tok total current} {
	variable maxbody
	if {$current > $maxbody} { ::http::reset $tok toobig }
}

# Decode a fetched body. geturl runs with -binary 1 (D118), so the body is
# the bytes off the wire: the sha256 must be the one the publisher's
# sha256sum saw, and http's own \r\n translation would break that.
#
#   1. A declared charset Tcl knows: decode with it.
#   2. Otherwise UTF-8, if the bytes round-trip. A repository is UTF-8, and
#      a plain webdir declares no charset; http's default, iso8859-1, would
#      corrupt every non-ASCII character at install.
#   3. Otherwise the bytes as they are.
proc rio::http::_decode {bytes ctype} {
	set cs ""
	regexp -nocase {charset\s*=\s*"?([^;"\s]+)} $ctype -> cs
	if {$cs ne ""} {
		set enc [_encoding_for $cs]
		if {$enc ne "" && ![catch {encoding convertfrom $enc $bytes} text]} { return $text }
	}
	if {[catch {set text [encoding convertfrom utf-8 $bytes]}]} { return $bytes }
	if {[encoding convertto utf-8 $text] ne $bytes} { return $bytes }
	return $text
}

# An IANA charset name -> Tcl's name for it, or "".
#   iso-8859-1 -> iso8859-1    windows-1252 -> cp1252    us-ascii -> ascii
proc rio::http::_encoding_for {cs} {
	set cs [string tolower [string trim $cs " \t\";"]]
	if {$cs eq ""} { return "" }
	set names [encoding names]
	foreach cand [list $cs \
			[regsub {^iso-8859-} $cs {iso8859-}] \
			[regsub {^(windows|cp)-} $cs {cp}] \
			[string map {us-ascii ascii utf8 utf-8} $cs]] {
		if {$cand in $names} { return $cand }
	}
	return ""
}

# The SHA-256 of a body as it arrived, hex (D118). Only on request: tcllib's
# sha256 is pure Tcl and slow.
proc rio::http::_sha256 {bytes} {
	return [::sha2::sha256 -hex $bytes]
}

# Resolve a redirect Location against the URL it came from:
#   http://x/y    as is           /path   keeps the origin
#   //host/path   keeps scheme    name    relative to the base's directory
proc rio::http::_resolve {base loc} {
	if {[regexp -nocase {^[a-z][a-z0-9+.-]*:} $loc]} { return $loc }
	regexp -nocase {^((https?)://[^/?#]+)([^?#]*)} $base -> origin scheme path
	if {[string range $loc 0 1] eq "//"} { return "[string tolower $scheme]:$loc" }
	if {[string index $loc 0] eq "/"}    { return "$origin$loc" }
	if {$path eq ""} { set path / }
	set dir [string range $path 0 [string last / $path]]
	return "$origin$dir$loc"
}

# http, https, or "" for anything this fetcher does not speak.
proc rio::http::_scheme {url} {
	if {[regexp -nocase {^(https?)://} $url -> s]} { return [string tolower $s] }
	return ""
}

# Before an https connection: tcltls is present and checks host names, or
# the user allowed https without that check (D114). A failure is an io_error
# that names the fix.
proc rio::http::_require_tls {} {
	if {[catch {rio::tls::ensure} e]} {
		if {[string match "*can't find package tls*" $e]} {
			rio::error::raise io_error "https needs tcltls on the core's host (apt/apk: tcl-tls; OpenBSD: tcltls) — install it and restart the core, or use the repository's http:// URL"
		}
		rio::error::raise io_error "https is unavailable on this core: $e"
	}
	if {![rio::tls::checks_hostname] && ![rio::tls::unchecked_ok]} {
		rio::error::raise io_error "https needs tcltls 1.8 or newer on the core's host — this core has tcltls [package present tls], which does not check that a certificate belongs to the server it came from. Upgrade it, use the repository's http:// URL, or, to accept this, turn on Preferences ▸ Network ▸ \"Allow https without host-name checks\""
	}
}

# Raise a failed fetch. For https, add the certificate's reason
# (rio::tls::explain). A certificate rio::tls refused gets its own code,
# untrusted_cert (D111): the user can accept it in the Extensions window.
proc rio::http::_fail {here scheme why} {
	if {$scheme eq "https"} {
		set why [rio::tls::explain $why]
		set origin [rio::tls::origin_of $here]
		set r [rio::tls::take_refusal $origin]
		if {$r ne ""} {
			if {[dict get $r changed]} {
				append why ". It is NOT the certificate you accepted for $origin — the server's certificate has changed since"
			}
			append why ". You can review the certificate and accept it in the Extensions window"
			rio::error::raise untrusted_cert "fetch $here failed: $why"
		}
	}
	rio::error::raise io_error "fetch $here failed: $why"
}

proc rio::http::get {url {timeout_ms 15000} {want_sha256 0}} {
	variable maxhops
	set here $url
	set prev ""
	for {set hop 0} {$hop <= $maxhops} {incr hop} {
		set scheme [_scheme $here]
		if {$scheme eq ""} {
			rio::error::raise io_error "not an http:// or https:// url: $here"
		}
		if {$prev eq "https" && $scheme eq "http"} {
			rio::error::raise io_error "refused a redirect from https to plain http ($here) — the repository was added as https, and following it would quietly drop that"
		}
		if {$scheme eq "https"} { _require_tls }
		set prev $scheme
		if {$scheme eq "https"} { rio::tls::take_refusal [rio::tls::origin_of $here] }
		if {[catch {
			::http::geturl $here -timeout $timeout_ms -binary 1 \
				-progress rio::http::_progress
		} tok]} {
			_fail $here $scheme $tok
		}
		if {[::http::status $tok] ne "ok"} {
			set why [::http::error $tok]
			if {$why eq ""} { set why [::http::status $tok] }
			::http::cleanup $tok
			if {$scheme eq "https"} { set why [lindex $why 0] }
			if {$why eq "toobig"} {
				variable maxbody
				set why "response exceeds the $maxbody byte cap"
			}
			_fail $here $scheme $why
		}
		set ncode [::http::ncode $tok]
		if {$ncode in {301 302 303 307 308}} {
			set loc ""
			foreach {k v} [::http::meta $tok] {
				if {[string equal -nocase $k location]} { set loc $v }
			}
			if {$loc ne ""} {
				::http::cleanup $tok
				set here [_resolve $here $loc]
				continue
			}
			# A redirect without a Location is nonsense; fall through as data.
		}
		set ctype ""
		catch {
			foreach {k v} [::http::meta $tok] {
				if {[string equal -nocase $k content-type]} { set ctype $v }
			}
		}
		set bytes [::http::data $tok]
		::http::cleanup $tok
		set out [dict create status $ncode url $here text [_decode $bytes $ctype]]
		if {$want_sha256} { dict set out sha256 [_sha256 $bytes] }
		return $out
	}
	rio::error::raise io_error "too many redirects fetching $url"
}

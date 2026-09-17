# rio-core — a bounded HTTP GET, http:// or https:// (AGENTS.md D39, D109).
#
# The fetch primitive behind extension repositories: repo.fetch (ops-repo.tcl)
# retrieves repository manifests, indexes, and payload files from plain
# HTTP-reachable directories. It lives CORE-side so the GUI grows no network
# code (INSTALL.md: a GUI-only box needs Tk and nothing else) and a remote
# core fetches from ITS network, not the frontend's.
#
#   rio::http::get url ?timeout_ms? -> {status <ncode> url <final-url> text <body>}
#
# HTTP IS FIRST-CLASS; HTTPS IS AN OPTION (D109) — the scheme in sources.list is
# the user's choice, as in apt's. Plain http needs nothing beyond Tcl. An https
# URL loads tcltls on first use (rio::tls, tls.tcl — the same verification the
# agent's transport uses) and needs tcltls 1.8+, the first that checks a
# certificate's name against the host; without it the fetch fails saying so,
# never quietly unverified. One redirect rule protects the choice: https → http
# is refused (apt refuses it too), while http → https is followed.
#
# BOUNDED, deliberately: at most 5 redirects followed (a loop exhausts the cap),
# and the body is capped at 2 MB — an extension payload is a Tcl file or a
# theme, not an archive, and the wire protocol carries the text onward. A
# COMPLETED exchange is data, whatever the status (a 404 tells the scanner "no
# index file here — try autoindex"); only not getting an answer — connection
# failure, timeout, the size cap, a redirect loop — raises io_error; a certificate
# rio::tls refused raises untrusted_cert instead (D111).
#
# Re-entrancy: the synchronous ::http::geturl pumps the event loop while it
# waits (its internal vwait), so other requests can arrive mid-fetch. That is
# safe here because a fetch touches no document state — it reads the network
# and returns; there is nothing to corrupt. Ops that mutate documents must not
# call this without considering that window.

package require http

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

# Decode a fetched body honestly (found live, 2026-09-12).
#
# ::http::data returns the body decoded with the charset the server DECLARED — and
# a plain webdir serving a repository declares none, so Tcl falls back to
# iso8859-1 (the old RFC 2616 default). Every non-ASCII byte then arrives as a
# separate latin-1 character: an em-dash comes back as U+00E2 U+0080 U+0094. The
# damage is not cosmetic — the GUI writes installed payloads back out as UTF-8, so
# those three characters become six bytes on disk and the extension is silently
# CORRUPTED at install time. (Observed: an installed provider's own option hints
# reading "â" on a core that fetched them through this.)
#
# A repository is rio's own D21 conf-and-Tcl, which is UTF-8, so an undeclared
# charset means UTF-8 here. The round-trip check keeps that from being a new
# guess: if the bytes are not valid UTF-8 (a genuinely latin-1 repository, or
# something binary), the re-encode won't match and we keep what http gave us
# rather than replacing characters with U+FFFD.
#
# The provider-side GET already did this (rio::llm::http::_on_get_end, D106); this
# is the older repository path, which never learned.
proc rio::http::_decode {body ctype} {
	if {[string match -nocase *charset=* $ctype]} { return $body }
	if {[catch {
		set bytes [encoding convertto iso8859-1 $body]
		set text  [encoding convertfrom utf-8 $bytes]
	}]} { return $body }
	if {[encoding convertto utf-8 $text] ne $bytes} { return $body }
	return $text
}

# Resolve a redirect Location against the URL it came from: absolute URLs pass
# through (a scheme change is `get`'s to judge, not this); /path keeps the origin;
# //host/path keeps the base's scheme; a bare relative path resolves against the
# base's directory.
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

# Before the first https connection: tcltls present, and new enough to check host
# names (rio::tls) — or the user allowed https without that check, the core-wide switch
# the agent shares (D114). Either failure is an io_error that names the fix — including
# the one that needs no install at all, the repository's http:// URL.
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

# Raise a failed fetch. For https, put the certificate's reason back into http's "failed to
# use socket" (rio::tls::explain), and when rio::tls refused the certificate itself say so
# with its own code, untrusted_cert (D111): that is the one failure the user can act on
# from the Extensions window — review the certificate and accept it — so a client must be
# able to tell it apart without reading the prose.
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

proc rio::http::get {url {timeout_ms 15000}} {
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
			::http::geturl $here -timeout $timeout_ms \
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
		set body [_decode [::http::data $tok] $ctype]
		::http::cleanup $tok
		return [dict create status $ncode url $here text $body]
	}
	rio::error::raise io_error "too many redirects fetching $url"
}

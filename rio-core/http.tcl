# rio-core — a bounded plain-HTTP GET (AGENTS.md D39).
#
# The fetch primitive behind extension repositories: repo.fetch (ops-repo.tcl)
# retrieves repository manifests, indexes, and payload files from plain
# HTTP-reachable directories. It lives CORE-side so the GUI grows no network
# code (INSTALL.md: a GUI-only box needs Tk and nothing else) and a remote
# core fetches from ITS network, not the frontend's.
#
#   rio::http::get url ?timeout_ms? -> {status <ncode> url <final-url> text <body>}
#
# PLAIN HTTP ONLY — rio implements no TLS of its own (D39): an https:// URL is
# refused up front (bad_request, in ops-repo.tcl). An operator who wants TLS
# fronts the webdir with relayd/nginx and publishes the http URL for rio, or
# rio waits for a later increment (ROADMAP: repository TLS / ssh transports).
# The Claude plugin's transport keeps its own tcltls setup, untouched — that
# is the plugin's dependency, not this fetcher's.
#
# BOUNDED, deliberately: at most 5 redirects followed (a loop exhausts the cap),
# and the body is capped at 2 MB — an extension payload is a Tcl file or a
# theme, not an archive, and the wire protocol carries the text onward. A
# COMPLETED exchange is data, whatever the status (a 404 tells the scanner "no
# index file here — try autoindex"); only not getting an answer — connection
# failure, timeout, the size cap, a redirect loop — raises io_error.
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

# Resolve a redirect Location against the URL it came from: absolute URLs pass
# through; /path keeps the origin; a bare relative path resolves against the
# base's directory. (https targets pass through too — and then fail the scheme
# check in `get`, honestly, rather than being silently rewritten.)
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

proc rio::http::_resolve {base loc} {
	if {[regexp -nocase {^[a-z][a-z0-9+.-]*:} $loc]} { return $loc }
	regexp -nocase {^(http://[^/?#]+)([^?#]*)} $base -> origin path
	if {[string range $loc 0 1] eq "//"} { return "http:$loc" }
	if {[string index $loc 0] eq "/"}    { return "$origin$loc" }
	if {$path eq ""} { set path / }
	set dir [string range $path 0 [string last / $path]]
	return "$origin$dir$loc"
}

proc rio::http::get {url {timeout_ms 15000}} {
	variable maxhops
	set here $url
	for {set hop 0} {$hop <= $maxhops} {incr hop} {
		if {![regexp -nocase {^http://} $here]} {
			rio::error::raise io_error "not an http:// url: $here"
		}
		if {[catch {
			::http::geturl $here -timeout $timeout_ms \
				-progress rio::http::_progress
		} tok]} {
			rio::error::raise io_error "fetch $here failed: $tok"
		}
		if {[::http::status $tok] ne "ok"} {
			set why [::http::error $tok]
			if {$why eq ""} { set why [::http::status $tok] }
			::http::cleanup $tok
			if {$why eq "toobig"} {
				variable maxbody
				set why "response exceeds the $maxbody byte cap"
			}
			rio::error::raise io_error "fetch $here failed: $why"
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

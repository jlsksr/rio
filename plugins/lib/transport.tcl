# plugins/lib — the shared HTTPS streaming transport (AGENTS.md D8/D26, D10).
#
# The network layer every LLM provider plugs into. Two command-prefix seams, both
# async via the http package + tcltls (event loop, D10), both taking
# req = {url, headers (flat {k v ...}), ?body?, ?timeout?} with status the HTTP code
# (0 = couldn't connect):
#   stream req on_chunk on_done  — a STREAMING POST for an SSE completions API,
#                                  delivering body chunks live (on_chunk <text>;
#                                  on_done <status> <err>)
#   get    req on_done           — a plain GET for one small document, e.g. the
#                                  vendor's model list (on_done <status> <err> <body>)
# TLS verifies the server cert against the system CA bundle when present. Nothing
# here is provider-specific — Claude and OpenAI share this copy.
#
# Sourced by more than one plugin loader (server.tcl loads each), so it is guarded
# to define its procs exactly once.

if {[llength [info commands rio::llm::http::stream]]} { return }

package require http

namespace eval rio::llm::http {
	variable tls_ready 0
}

# Register https with tcltls once, verifying the peer cert where we can.
proc rio::llm::http::_ensure_tls {} {
	variable tls_ready
	if {$tls_ready} return
	package require tls
	::http::register https 443 [list rio::llm::http::_tls_socket]
	set tls_ready 1
}
proc rio::llm::http::_tls_socket {args} {
	set opts [list -autoservername 1 -require 1]
	# The system CA bundle, wherever this platform keeps it: Debian/Alpine,
	# RHEL-family, then OpenBSD (also macOS) — rio's supported hosts (D4).
	foreach ca {/etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem} {
		if {[file exists $ca]} { lappend opts -cafile $ca ; break }
	}
	return [::tls::socket {*}$opts {*}$args]
}

# Split a flat header list into the Content-Type (-> ctypeVar) and the rest.
proc rio::llm::http::_headers {headers ctypeVar} {
	upvar 1 $ctypeVar ctype
	set ctype application/json
	set out {}
	foreach {k v} $headers {
		if {[string equal -nocase $k Content-Type]} { set ctype $v } else { lappend out $k $v }
	}
	return $out
}

# --- streaming POST (the SSE completions API) --------------------------------
proc rio::llm::http::stream {req on_chunk on_done} {
	if {[catch {_ensure_tls} e]} { {*}$on_done 0 $e ; return }
	set hlist [_headers [dict get $req headers] ctype]
	# -timeout is the WHOLE-request budget, and a streaming turn (a long
	# generation, or several tool round-trips) can legitimately take minutes —
	# too tight a cap severs it mid-stream and mislabels it a network error. Keep
	# a generous default and let the face override it as data (D26 request_timeout).
	set timeout [expr {[dict exists $req timeout] ? [dict get $req timeout] : 600000}]
	if {[catch {
		::http::geturl [dict get $req url] -method POST \
			-query [dict get $req body] -type $ctype -headers $hlist \
			-handler [list rio::llm::http::_on_data $on_chunk] \
			-command [list rio::llm::http::_on_end $on_done] \
			-timeout $timeout
	} err]} {
		{*}$on_done 0 $err
	}
}

# --- plain GET (a small JSON document: the vendor's model list) ---------------
#
# The second seam (D106): one request, one whole body — no streaming, because a
# models listing is a few kB that is useless in pieces. Same request shape as
# `stream` minus the body, and the same "never block the core" rule (D10): the
# reply arrives on the callback, in the event loop.
#   get req on_done   — on_done <status> <err> <body>; status 0 = couldn't connect
proc rio::llm::http::get {req on_done} {
	if {[catch {_ensure_tls} e]} { {*}$on_done 0 $e "" ; return }
	set hlist [_headers [dict get $req headers] ctype]
	set timeout [expr {[dict exists $req timeout] ? [dict get $req timeout] : 30000}]
	if {[catch {
		::http::geturl [dict get $req url] -method GET -headers $hlist \
			-command [list rio::llm::http::_on_get_end $on_done] -timeout $timeout
	} err]} {
		{*}$on_done 0 $err ""
	}
}

# A JSON response is `application/json`, which the http package treats as BINARY —
# so ::http::data hands back raw bytes and the utf-8 decode is ours to do, exactly as
# the streaming path does it at the socket. When the server did declare a charset,
# http has already decoded, and decoding twice would mangle every non-ASCII name.
proc rio::llm::http::_on_get_end {on_done token} {
	lassign [_status $token] status err
	set body [::http::data $token]
	set ctype ""
	catch {set ctype [dict get [::http::meta $token] content-type]}
	if {![string match -nocase *charset=* $ctype]} {
		catch {set body [encoding convertfrom utf-8 $body]}
	}
	::http::cleanup $token
	{*}$on_done $status $err $body
}

# Per-chunk: hand the decoded text to on_chunk. Decoding at the socket (utf-8)
# means partial multibyte sequences at a chunk boundary are held by Tcl until
# complete, so on_chunk only ever sees whole characters.
proc rio::llm::http::_on_data {on_chunk sock token} {
	fconfigure $sock -encoding utf-8 -translation lf
	set chunk [read $sock]
	{*}$on_chunk $chunk
	return [string length $chunk]
}

proc rio::llm::http::_on_end {on_done token} {
	lassign [_status $token] status err
	::http::cleanup $token
	{*}$on_done $status $err
}

# Map an http token to {status err}: a completed HTTP exchange (even a 4xx/5xx)
# is {<ncode> ""}; a connection failure/timeout/reset is {0 <reason>}.
proc rio::llm::http::_status {token} {
	if {[::http::status $token] eq "ok"} {
		return [list [::http::ncode $token] ""]
	}
	set err [::http::error $token]
	if {$err eq ""} { set err [::http::status $token] }
	return [list 0 $err]
}

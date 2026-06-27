# rio-core — generic OAuth browser-sign-in plumbing (AGENTS.md D26).
#
# The *generic* half of OAuth, reusable by any provider/plugin that needs a
# browser sign-in: PKCE (RFC 7636) code generation, opening the user's browser,
# and a one-shot loopback HTTP listener that catches the redirect and hands back
# its query parameters. The provider-SPECIFIC half — the authorize/token
# endpoints, client id, scopes, and the code->token exchange — lives in the
# provider (e.g. the claude-oauth face), which calls these services. Keeping the
# volatile specifics out of here is the D26 resilience split.
#
# Event-loop driven (D10), Tk-free (D1). No network of its own beyond a localhost
# listener — the browser connects back to it; nothing here talks to a remote host.

namespace eval rio::oauth {
	variable seq 0
	variable state {}     ;# listener id -> {cb <prefix> srv <chan>}
	# The browser launcher, overridable for tests/headless. Empty = auto-detect.
	variable opener ""
}

# --- PKCE (RFC 7636) ---------------------------------------------------------
# A {verifier, challenge, method} triple: the verifier is a 43-char base64url of
# 32 random bytes; the challenge is base64url(SHA-256(verifier)); method S256.
proc rio::oauth::pkce {} {
	set verifier [_b64url [_randbytes 32]]
	set challenge [_b64url [_sha256 $verifier]]
	return [dict create verifier $verifier challenge $challenge method S256]
}

proc rio::oauth::_sha256 {bytes} {
	package require sha256
	return [::sha2::sha256 -bin $bytes]
}

# base64url WITHOUT padding (the OAuth/JOSE convention).
proc rio::oauth::_b64url {bytes} {
	return [string map {+ - / _ = {}} [binary encode base64 $bytes]]
}

# Cryptographically-random bytes from the OS; a non-crypto fallback only if there
# is no /dev/urandom (kept so the proc never fails, e.g. on Windows where the
# provider should prefer a platform RNG later).
proc rio::oauth::_randbytes {n} {
	if {![catch {open /dev/urandom rb} f]} {
		fconfigure $f -translation binary
		set b [::read $f $n]
		close $f
		if {[string length $b] == $n} { return $b }
	}
	set b ""
	for {set i 0} {$i < $n} {incr i} { append b [binary format c [expr {int(rand() * 256)}]] }
	return $b
}

# --- the browser --------------------------------------------------------------
# Open a URL in the user's default browser. Returns 1 on a launch attempt, 0 if
# no launcher is available. Overridable via the `opener` variable (a command
# prefix taking the URL) for tests or unusual environments.
proc rio::oauth::browser_open {url} {
	variable opener
	if {$opener ne ""} { return [{*}$opener $url] }
	if {$::tcl_platform(platform) eq "windows"} {
		return [expr {![catch {exec {*}[auto_execok start] {} $url &}]}]
	}
	set cmd [expr {$::tcl_platform(os) eq "Darwin" ? "open" : "xdg-open"}]
	return [expr {![catch {exec $cmd $url &}]}]
}

# --- the loopback redirect catcher -------------------------------------------
# Start a one-shot HTTP listener on 127.0.0.1:<ephemeral>. Returns
# {port, redirect, id}; `redirect` is the URI to register as the OAuth
# redirect_uri. On the first GET (the browser following the provider's redirect),
# it replies with a small "you can close this tab" page, stops listening, and
# invokes `cb` with the request's query parameters as a dict (e.g. {code .. state ..}).
proc rio::oauth::loopback_listen {cb} {
	variable seq
	variable state
	set id [incr seq]
	set srv [socket -myaddr 127.0.0.1 -server [list rio::oauth::_accept $id] 0]
	set port [lindex [fconfigure $srv -sockname] 2]
	dict set state $id [dict create cb $cb srv $srv]
	return [dict create port $port redirect "http://127.0.0.1:$port/callback" id $id]
}

# Tear down a listener early (e.g. the user cancelled before signing in).
proc rio::oauth::loopback_cancel {id} {
	variable state
	if {[dict exists $state $id]} {
		catch {close [dict get $state $id srv]}
		dict unset state $id
	}
}

proc rio::oauth::_accept {id chan addr port} {
	fconfigure $chan -translation crlf -blocking 0 -buffering line -encoding utf-8
	fileevent $chan readable [list rio::oauth::_read $id $chan]
}

proc rio::oauth::_read {id chan} {
	variable state
	if {[catch {gets $chan line} n]} { catch {close $chan} ; return }
	if {$n < 0} { if {[eof $chan]} { catch {close $chan} } ; return }
	# Only the request line interests us: "GET /callback?code=..&state=.. HTTP/1.1".
	if {![regexp {^GET\s+(\S+)\s+HTTP} $line -> target]} { return }
	set query [_query $target]
	_respond $chan
	catch {close $chan}
	# One-shot: stop listening and fire the callback exactly once.
	if {[dict exists $state $id]} {
		set cb [dict get $state $id cb]
		catch {close [dict get $state $id srv]}
		dict unset state $id
		{*}$cb $query
	}
}

proc rio::oauth::_respond {chan} {
	set body "<!doctype html><html><head><meta charset=\"utf-8\"><title>rio</title></head>\
<body style=\"font-family:sans-serif;text-align:center;margin-top:4em\">\
<h2>Signed in to rio</h2><p>You can close this tab and return to the editor.</p></body></html>"
	puts $chan "HTTP/1.1 200 OK"
	puts $chan "Content-Type: text/html; charset=utf-8"
	puts $chan "Content-Length: [string length $body]"
	puts $chan "Connection: close"
	puts $chan ""
	puts -nonewline $chan $body
	flush $chan
}

# Parse the query string of a request target into a dict, percent-decoding values.
proc rio::oauth::_query {target} {
	set q [dict create]
	if {![regexp {\?(.*)$} $target -> qs]} { return $q }
	foreach pair [split $qs &] {
		if {$pair eq ""} continue
		set eq [string first = $pair]
		if {$eq < 0} {
			dict set q [_urldecode $pair] ""
		} else {
			dict set q [_urldecode [string range $pair 0 [expr {$eq - 1}]]] \
				[_urldecode [string range $pair [expr {$eq + 1}] end]]
		}
	}
	return $q
}

proc rio::oauth::_urldecode {s} {
	set s [string map {+ " "} $s]
	set out ""
	set n [string length $s]
	for {set i 0} {$i < $n} {incr i} {
		set ch [string index $s $i]
		if {$ch eq "%" && $i + 2 < $n} {
			append out [format %c 0x[string range $s [expr {$i + 1}] [expr {$i + 2}]]]
			incr i 2
		} else {
			append out $ch
		}
	}
	return $out
}

# plugins/lib — the shared HTTPS streaming transport (D8/D26, D10).
#
# The network layer of every LLM provider. Two calls, both asynchronous
# (http + tcltls in the event loop, D10):
#
#   stream req on_chunk on_done   a streaming POST, for an SSE API
#       on_chunk <text>           each piece of the body, as it arrives
#       on_done  <status> <err>
#   get req on_done               a GET of one small document
#       on_done  <status> <err> <body>
#
#   req      {url <u> headers {k v ...} ?body <s>? ?timeout <ms>?}
#   status   the HTTP code; 0 = no connection, and <err> says why
#
# rio::tls (rio-core/tls.tcl, D109) decides how a certificate is verified.
#
# Several plugin loaders source this file; the guard defines it once.

if {[llength [info commands rio::llm::http::stream]]} { return }

package require http
# The core has loaded rio::tls already; this file's own tests have not.
if {![llength [info commands rio::tls::socket]]} {
	source [file join [file dirname [file normalize [info script]]] .. .. rio-core tls.tcl]
}

namespace eval rio::llm::http {}

# Load tcltls, and refuse an https URL this core cannot verify (D110). A
# tcltls before 1.8 checks a certificate's chain but not its host name; that
# is allowed only if the user said so (rio::tls::unchecked_ok, D114). Plain
# http passes. Providers match "the agent refused https to" in the message.
proc rio::llm::http::_ensure_tls {url} {
	rio::tls::ensure
	if {![regexp -nocase {^https://([^/?#]*)} $url -> host]} return
	if {[rio::tls::checks_hostname]} return
	if {[rio::tls::unchecked_ok]} return
	error "tcltls [package present tls] on the core's host does not check that a certificate belongs to the server it came from, so the agent refused https to $host. Install tcltls 1.8 or newer and restart the core — or, to accept this, turn on Preferences ▸ Network ▸ \"Allow https without host-name checks\""
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
	if {[catch {_ensure_tls [dict get $req url]} e]} { {*}$on_done 0 $e ; return }
	set hlist [_headers [dict get $req headers] ctype]
	# -timeout covers the whole request, and a turn can take minutes: 10
	# minutes unless the request says otherwise.
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

# --- plain GET (a small JSON document: the vendor's model list, D106) ---------
proc rio::llm::http::get {req on_done} {
	if {[catch {_ensure_tls [dict get $req url]} e]} { {*}$on_done 0 $e "" ; return }
	set hlist [_headers [dict get $req headers] ctype]
	set timeout [expr {[dict exists $req timeout] ? [dict get $req timeout] : 30000}]
	if {[catch {
		::http::geturl [dict get $req url] -method GET -headers $hlist \
			-command [list rio::llm::http::_on_get_end $on_done] -timeout $timeout
	} err]} {
		{*}$on_done 0 $err ""
	}
}

# http treats application/json as binary, so decode utf-8 here. Not if the
# server named a charset: then http has decoded already.
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

# Hand each chunk to on_chunk. The socket decodes utf-8, so a character
# split across two chunks arrives whole.
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

# An http token as {status err}: {<code> ""} for any completed exchange,
# a 4xx or 5xx too; {0 <reason>} for a failure, timeout or reset.
proc rio::llm::http::_status {token} {
	if {[::http::status $token] eq "ok"} {
		return [list [::http::ncode $token] ""]
	}
	set err [::http::error $token]
	if {$err eq ""} { set err [::http::status $token] }
	# A refused certificate reaches http as "failed to use socket";
	# rio::tls kept the real reason.
	if {![catch {lindex $err 0} msg]} {
		set told [rio::tls::explain $msg]
		if {$told ne $msg} { set err $told }
	}
	return [list 0 $err]
}

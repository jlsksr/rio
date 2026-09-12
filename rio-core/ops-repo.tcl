# rio-core — the repo.* op namespace (AGENTS.md D39, D11).
#
# One op: the fetch primitive extension repositories are built on. The GUI
# does all the interpreting (manifests, indexes, install targets); the core
# just retrieves a URL, bounded (rio::http — ≤5 redirects, 2 MB cap).
#
# Trust posture: like exec.run, this op is as open as the channel it arrives
# on (D30 — whoever may talk to the core may use its network). It fetches
# http:// or https:// (D109): plain http is first-class, https an option that
# needs tcltls 1.8+ on the core's host (rio::http / rio::tls say so when absent).
#
# Re-entrancy: a fetch pumps the event loop while it waits (rio::http header),
# and touches no document state — other requests interleaving with it is safe.

# repo.fetch {url ?timeout?} -> {status <ncode> url <final-url> text <body>}
# A completed exchange is data whatever the status (a 404 is an answer); only
# not getting an answer — connect failure, timeout, cap, redirect loop — is an
# io_error. `timeout` is in milliseconds.
proc rio::ops::repo_fetch {params} {
	if {![dict exists $params url]} {
		rio::error::raise bad_request "repo.fetch requires url"
	}
	set url [dict get $params url]
	if {![regexp -nocase {^https?://} $url]} {
		rio::error::raise bad_request "repo.fetch takes an http:// or https:// url, got: $url"
	}
	set timeout [expr {[dict exists $params timeout] ? [dict get $params timeout] : 15000}]
	if {![string is integer -strict $timeout] || $timeout <= 0} {
		rio::error::raise bad_request "repo.fetch timeout must be a positive integer (ms)"
	}
	return [dict create result [rio::http::get $url $timeout]]
}
rio::dispatch::register repo.fetch rio::ops::repo_fetch

# rio-core — the repo.* op namespace (D39, D11).
#
# One op: fetch a URL for the extension repositories (rio::http). The GUI
# interprets what comes back. As open as the channel it arrives on (D30):
# whoever may talk to the core may use its network.

# repo.fetch {url ?timeout? ?sha256 0|1?}
#     -> {status <ncode> url <final-url> text <body> ?sha256 <hex>?}
#
# - A completed exchange is data, whatever the status. No answer is an
#   io_error; a refused https certificate is untrusted_cert (D111).
# - `timeout` is in milliseconds.
# - `sha256` asks for the hash of the body's bytes as they arrived (D118).
#   Only on request: it is slow.
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
	set want [expr {[dict exists $params sha256] ? [dict get $params sha256] : 0}]
	if {![string is boolean -strict $want]} {
		rio::error::raise bad_request "repo.fetch sha256 must be 0 or 1, got: $want"
	}
	return [dict create result [rio::http::get $url $timeout [expr {$want ? 1 : 0}]]]
}
rio::dispatch::register repo.fetch rio::ops::repo_fetch

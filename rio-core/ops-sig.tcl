# rio-core — the sig.* op namespace (D118, D11).
#
# Verify a detached OpenSSH signature over some text. It knows nothing of
# repositories: text, a signature and a key in, an answer out (rio::sig).
# As open as the channel it arrives on (D30); it writes only temp files.
#
# sig.verify {data sig key ?principal? ?namespace? ?sha256?}
#   -> {verified 0|1 available 0|1 fingerprint <SHA256:…> signer <SHA256:…> reason <s>}
#
# - `available 0` is not a bad signature: the core's host has no usable
#   ssh-keygen. The caller decides what that means.
# - `sha256` is the hash of the original bytes, as repo.fetch reported it. A
#   signature covers bytes, and the client held them as text. If `data`
#   re-encoded as UTF-8 has another hash, the op says so, not "bad signature".

rio::deps::require sha256

proc rio::ops::sig_verify {params} {
	foreach k {data sig key} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "sig.verify requires $k"
		}
	}
	set data [dict get $params data]
	set sig  [dict get $params sig]
	set key  [string trim [dict get $params key]]
	set principal [expr {[dict exists $params principal] ? [dict get $params principal] : "rio"}]
	set ns [expr {[dict exists $params namespace] && [dict get $params namespace] ne ""
		? [dict get $params namespace] : $rio::sig::namespace_default}]
	set bytes [encoding convertto utf-8 $data]
	if {[dict exists $params sha256] && [dict get $params sha256] ne ""} {
		set want [string tolower [dict get $params sha256]]
		if {![regexp {^[0-9a-f]{64}$} $want]} {
			rio::error::raise bad_request "sig.verify: sha256 must be 64 hex digits"
		}
		if {[::sha2::sha256 -hex $bytes] ne $want} {
			return [dict create result [dict create available 1 verified 0 \
				signer "" fingerprint [rio::sig::fingerprint $key] \
				reason "the signed bytes couldn't be reconstructed here — the file changed between fetching it and checking it, or it isn't the UTF-8 text rio took it for"]]
		}
	}
	return [dict create result [rio::sig::verify $data $sig $key $principal $ns]]
}
rio::dispatch::register sig.verify rio::ops::sig_verify

# sig.fingerprint {key} -> {fingerprint <SHA256:…>}
#
# What a user sees when asked to trust a key: the string `ssh-keygen -lf`
# prints. "" for a bad key or no ssh-keygen; not an error, so the client can
# say it has no fingerprint.
proc rio::ops::sig_fingerprint {params} {
	if {![dict exists $params key]} {
		rio::error::raise bad_request "sig.fingerprint requires key"
	}
	return [dict create result [dict create \
		fingerprint [rio::sig::fingerprint [string trim [dict get $params key]]]]]
}
rio::dispatch::register sig.fingerprint rio::ops::sig_fingerprint

# rio-core — the sig.* op namespace (AGENTS.md D118, D11).
#
# One op: verify a detached OpenSSH signature over some text. It is the repository
# signature check (D39's trust model), but nothing here knows about repositories —
# it takes bytes, a signature and a key, and answers. That keeps it free of the
# network and testable against committed fixtures.
#
# Trust posture: like repo.fetch, as open as the channel it arrives on (D30). It
# reads no file of the user's, writes only temp files, and spawns one fixed program
# with an argv rio built (rio::sig).
#
# sig.verify {data sig key ?principal? ?namespace? ?sha256?}
#   -> {verified 0|1 available 0|1 fingerprint <SHA256:…> signer <SHA256:…> reason <s>}
#
# `available 0` is NOT a bad signature: it means the core's host has no ssh-keygen,
# or one older than OpenSSH 8.0. The caller's policy decides what that is worth; the
# two must never collapse into each other.
#
# THE sha256 GUARD. A signature covers bytes, but a client holds the signed file as
# TEXT — it was decoded on the way in and re-encoded on the way here (D30's wire is
# JSON). `sha256`, when given, is the hash of the ORIGINAL bytes as the core itself
# reported them from repo.fetch: this op re-encodes `data` as UTF-8 and checks that
# it lands on the same hash before asking ssh-keygen anything. A round trip that lost
# something then says so in those words, instead of arriving as "bad signature" —
# the one failure a user must never see for a repository that was fine.

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
# What a user is shown when they are asked to trust a key — the same string
# `ssh-keygen -lf` prints, so it can be compared with what a publisher quotes out of
# band. "" when the key is junk or there is no ssh-keygen to ask; a client showing a
# key it cannot fingerprint has to say so, which is why this is an empty answer
# rather than an error.
proc rio::ops::sig_fingerprint {params} {
	if {![dict exists $params key]} {
		rio::error::raise bad_request "sig.fingerprint requires key"
	}
	return [dict create result [dict create \
		fingerprint [rio::sig::fingerprint [string trim [dict get $params key]]]]]
}
rio::dispatch::register sig.fingerprint rio::ops::sig_fingerprint

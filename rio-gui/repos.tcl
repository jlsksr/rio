# rio-gui/repos.tcl — extension repositories: sources, signatures, the ledger, scanning.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Extension repositories (D39). The apt-sources model, over plain
# HTTP: sources.list holds base URLs, each pointing at a webdir that hosts
# rio-repository.conf (the marker+manifest), an optional `index`, and one
# subdirectory per extension carrying rio-extension.conf + its payload files.
# No central index, no accounts — provenance (source URL + version) is
# recorded per installed extension in a local ledger, and same-name extensions
# from different sources coexist in listings for the USER to choose between.
#
# The split of labour: the CORE fetches (repo.fetch — bounded, plain http, so
# a remote core uses ITS network) and stores themes (theme.put/delete — theme
# files are the core's to read); the GUI interprets — parses manifests (conf
# DATA, never executed), asks consent, installs syntax/mode payloads into its
# own drop-in dirs (they run in the FRONTEND), and keeps the ledger. Remote
# caveat, recorded honestly: the ledger says "this GUI installed X onto its
# core" — a second frontend on the same daemon doesn't see it (ROADMAP).
#
# Every REMOTE-SUPPLIED name (extension dir, name, kind, payload filename)
# must pass ext_safe_name before it is joined into a URL or a path — that one
# rule kills traversal and percent-encoding games at the format level.
# ---------------------------------------------------------------------------

set ::ext_ledger {}     ;# "kind/name" -> {source dir version files installed ?anysource?} (ledger_load)
set ::provider_api_max 4 ;# highest provider-api the core loads (provider.list; D66)
# Highest mode-api THIS GUI implements (D123, modes/registry.tcl). A literal, not a
# core round-trip like provider_api_max above: a provider is sourced into the core, so
# the core is the party that knows its ceiling, but a mode is sourced into the FRONTEND
# — the GUI is the one that knows.
set ::mode_api_max 1
set ::repo_variants {}  ;# every installable variant found by the last scan
set ::repo_dead {}      ;# {url error code} per unreachable/non-repository source
set ::repo_srcinfo {}   ;# source url -> {name description} from its manifest
set ::ext_core_providers {} ;# name -> {version source} from provider.list (D107)
set ::ext_installed {} ;# "kind/name" -> {version source} — what is installed, ledger + core
set ::ext_updates {}   ;# "kind/name" -> {from to variant} — what a source now offers (D107)

proc ext_safe_name {s} {
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $s]
}

# --- versions: semver, and compared (D107) ---------------------------
# D39 froze `version` as an opaque string rio never compares, which left the user
# to eyeball "is mine still current?". D107 replaces that with a published rule —
# an extension version is semver (semver.org) — and this comparator.
#
# The parse is deliberately LENIENT about the one thing the spec is strict on:
# 1-3 numeric core components, missing ones zero, so `1.1` reads as `1.1.0`. The
# rule is new and every version installed anywhere predates it (rio's own
# extensions shipped as `1.0`/`1.1`); refusing those would blind the feature on
# exactly the installs it exists for. Everything else follows the spec: an
# optional `-prerelease` of dot-separated identifiers, `+build` ignored.
#
# Returns {core {maj min patch} pre {id …}} or "" — and "" is a real answer, for
# `2026-07-17`, `v2-final`, anything not following the rule. Such an extension
# still lists, still installs, and simply never carries an update claim: D39's
# opacity survives precisely where the rule isn't followed.
proc ext_ver_parse {s} {
	set s [string trim $s]
	if {$s eq ""} { return "" }
	set plus [string first + $s]
	if {$plus >= 0} { set s [string range $s 0 $plus-1] }   ;# build metadata: ignored
	set pre {}
	set dash [string first - $s]
	if {$dash >= 0} {
		set pre [split [string range $s $dash+1 end] .]
		set s [string range $s 0 $dash-1]
		if {![llength $pre]} { return "" }
		foreach id $pre {
			if {![regexp {^[0-9A-Za-z-]+$} $id]} { return "" }
		}
	}
	set parts [split $s .]
	if {[llength $parts] < 1 || [llength $parts] > 3} { return "" }
	# The short-form allowance is for `1.1` and nothing else. Combined with a
	# pre-release it starts reading strings that are not versions at all as if they
	# were — `2026-07-17` would parse as 2026.0.0-07-17 — so a pre-release requires
	# the full three-component core the spec asks for.
	if {[llength $pre] && [llength $parts] != 3} { return "" }
	set core {}
	foreach p $parts {
		# `string is integer` would accept 0x10 and a leading +/-; a version component
		# is digits, nothing else.
		if {![regexp {^[0-9]+$} $p]} { return "" }
		lappend core [scan $p %d]   ;# scan, not expr: 010 is ten, not an octal error
	}
	while {[llength $core] < 3} { lappend core 0 }
	return [dict create core $core pre $pre]
}

# Compare two version STRINGS: -1 / 0 / 1, or "" when either side doesn't parse.
# Callers must treat "" as "no claim can be made" — never as equality.
proc ext_ver_cmp {a b} {
	set pa [ext_ver_parse $a]
	set pb [ext_ver_parse $b]
	if {$pa eq "" || $pb eq ""} { return "" }
	foreach x [dict get $pa core] y [dict get $pb core] {
		if {$x < $y} { return -1 }
		if {$x > $y} { return 1 }
	}
	set ra [dict get $pa pre]
	set rb [dict get $pb pre]
	# A pre-release ranks BELOW the release it leads to: 1.0.0-beta < 1.0.0.
	if {![llength $ra] && ![llength $rb]} { return 0 }
	if {![llength $ra]} { return 1 }
	if {![llength $rb]} { return -1 }
	foreach x $ra y $rb {
		# `foreach` over uneven lists pads with "" — the shorter list runs out first,
		# and a version with FEWER identifiers ranks lower (1.0.0-alpha < 1.0.0-alpha.1).
		if {$x eq ""} { return -1 }
		if {$y eq ""} { return 1 }
		set nx [regexp {^[0-9]+$} $x]
		set ny [regexp {^[0-9]+$} $y]
		if {$nx && $ny} {
			set x [scan $x %d] ; set y [scan $y %d]
			if {$x < $y} { return -1 }
			if {$x > $y} { return 1 }
		} elseif {$nx} {
			return -1              ;# numeric identifiers rank below alphanumeric ones
		} elseif {$ny} {
			return 1
		} else {
			set c [string compare $x $y]
			if {$c != 0} { return [expr {$c < 0 ? -1 : 1}] }
		}
	}
	return 0
}

# --- sources.list -------------------------------------------------------------
proc sources_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio sources.list]
}

# One base URL per line, # comments — hand-editable; the Repositories… editor
# writes the same format back.
proc sources_load {} {
	set path [sources_path]
	if {$path eq "" || ![file exists $path]} { return {} }
	set urls {}
	if {[catch {set text [slurp_utf8 $path]}]} { return {} }
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {$t ni $urls} { lappend urls $t }
	}
	return $urls
}

proc sources_save {urls} {
	set path [sources_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts $f "# rio extension repositories — one http:// or https:// base URL per line (D39, D109)."
		foreach u $urls { puts $f $u }
		close $f
	}
}

# The repository rio ships pre-configured (D39): the project's own extension repo, so a
# fresh install has something to browse in the Extensions window out of the box. Seeded into
# sources.list ONLY on a true first run — when the file does not yet exist — so a user who
# removes it in Repositories… (which leaves a header-only file behind) is never re-seeded.
# No trailing slash: repo_source_scan appends "/rio-repository.conf" to the base.
set ::default_repo "http://rio.skylm.org/extensions"
proc sources_seed_default {} {
	set path [sources_path]
	if {$path eq "" || [file exists $path]} return
	sources_save [list $::default_repo]
}

# --- signing: which key speaks for a repository (D118, D119) ---------
#
# D39 keeps plain http first-class, which means anyone on the path between a user
# and a repository can rewrite a payload in flight. A signature over the repository
# is what makes that fail without a registry or an account: the publisher signs one
# root SHA256SUMS with an ssh key (their SIGNING.md), rio checks that signature and
# then checks every file it fetches against those hashes.
#
# TRUSTED WHEN THE USER SAYS SO, with a seed (D119). A repository publishes its
# public key in rio-repository.conf. The first scan that verifies against it does NOT
# record it: it refuses the source as `key_unconfirmed` and offers the fingerprint,
# the way ssh prints one and waits for `yes`. Once confirmed, that key — and only that
# key — speaks for that source; a different key later is refused as `key_changed`
# until the user trusts that one too (D111's shape for a changed certificate). The
# default source ships with the project's own key already trusted, so a fresh rio is
# not asked a question it has no way to answer; the keys window can withdraw even
# that.
#
# WHAT CONFIRMING CANNOT DO, said plainly: an attacker already on the path the very
# first time still gets to offer a marker, a SHA256SUMS and a signature made by their
# own key, and rio has nothing to compare it against. What it buys is that they must
# now get a human to accept a fingerprint the publisher's own page contradicts,
# instead of winning silently and permanently.
#
# The keys live GUI-SIDE, beside sources.list: the sources list is the trust list
# (D39), and a key is a property of an entry in it. The verifying is the CORE's
# (sig.verify), because ssh-keygen must be on the host that has the tool — the same
# split as tcltls and https (D109).

set ::repo_keys {}   ;# scheme-less source -> {key <type+base64> trusted <date> forgotten <date>}
set ::repo_sig  {}   ;# source -> {state signed|unsigned|unverified signer <fp> sums {path hash …}}

# May a repository rio CANNOT check be used anyway? Off by default, and it buys
# exactly one thing: a source whose key is trusted, on a host with no ssh-keygen to
# check it with, lists and installs — marked `unverified` in every place a signed one
# would say `signed`, and named as such in the install consent. It does NOT touch a
# bad signature, a changed key or a mismatched hash: those are refusals whatever this
# says. The same shape as D114's switch for an https that can't check host names —
# fail closed, with one explicit way out that never hides which way was taken.
# (Prefs, not the core's conf, because unlike D114 this governs nothing but the
# Extensions window; the agent's transport is not involved.)
set ::repo_allow_unverified 0   ;# the preference (prefs.json `allow_unverified_repos`)

# The key rio trusts for its own repository out of the box. Published as the `key =`
# line of http://rio.skylm.org/extensions/rio-repository.conf; fingerprint
# SHA256:ThigJDQbjz1G8yvZMJ7grlLlcOA6uS+ZDWvJdJPVfG0, which is the one to confirm
# out of band. A stored entry always wins over this, so trusting a rotation by hand
# is never undone by the seed.
set ::default_repo_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzSB7e8mVA9R+JndUZAIliRW2sxKlUD5P4AMoZuIzLV"

proc repo_keys_path {} {
	set p [sources_path]
	if {$p eq ""} { return "" }
	return [file join [file dirname $p] repository-keys.conf]
}

# `[<scheme-less source>]` sections carrying `key` and `trusted` — rio's own conf
# format (D21), hand-editable on purpose: deleting a section is how a user takes a
# trust decision back, and is exactly what repo_keys_forget does for them.
#
# A section with NO `key` is meaningful and is kept (D119): it says rio knows this
# source and trusts no key for it. That is the only way to withdraw the key rio ships
# with for its own repository, which is a fallback rather than a stored entry — so
# `forgotten = <date>` beats the seed, and repo_key_of stops falling back to it.
proc repo_keys_load {} {
	set ::repo_keys {}
	set path [repo_keys_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {rio::conf::parse [slurp_utf8 $path]} conf]} return
	dict for {section kv} $conf {
		if {$section eq ""} continue
		dict set ::repo_keys $section [dict create \
			key [expr {[dict exists $kv key] ? [string trim [dict get $kv key]] : ""}] \
			trusted [expr {[dict exists $kv trusted] ? [dict get $kv trusted] : ""}] \
			forgotten [expr {[dict exists $kv forgotten] ? [dict get $kv forgotten] : ""}]]
	}
}

proc repo_keys_save {} {
	set path [repo_keys_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts $f "# Signing keys rio trusts for extension repositories (D118, D119). One section"
		puts $f "# per repository, written when you confirmed that repository's key."
		puts $f "#"
		puts $f "# Delete a section to forget that key: rio then asks again the next time"
		puts $f "# that repository is scanned, and installs nothing from it until you say"
		puts $f "# yes. A section with no key at all means the opposite of trust - rio"
		puts $f "# trusts no key here, not even one it ships with. The same edits are one"
		puts $f "# click in Preferences > Extensions > Repository signing keys..."
		dict for {src e} $::repo_keys {
			puts $f ""
			puts $f "\[$src\]"
			if {[dict get $e key] ne ""} {
				puts $f "key = [dict get $e key]"
				if {[dict get $e trusted] ne ""} { puts $f "trusted = [dict get $e trusted]" }
			} elseif {[dict get $e forgotten] ne ""} {
				puts $f "forgotten = [dict get $e forgotten]"
			}
		}
		close $f
	}
}

# The key trusted for a source, or "". Scheme-less, like source_same: moving a
# repository from http:// to https:// (D109) is a change of route, not of publisher,
# and must not read as a rotated key.
#
# A stored section answers even when it carries no key: "" then means rio trusts
# nothing here, and the seed below is NOT reached — that is what makes the built-in
# key withdrawable (D119).
proc repo_key_of {source} {
	set key [source_key $source]
	dict for {src e} $::repo_keys {
		if {$src eq $key} { return [dict get $e key] }
	}
	if {[source_same $source $::default_repo]} { return $::default_repo_key }
	return ""
}

proc source_key {source} {
	regsub -nocase {^https?://} [string trimright $source /] {} s
	return $s
}

proc repo_key_trust {source key} {
	dict set ::repo_keys [source_key $source] [dict create \
		key $key trusted [clock format [clock seconds] -format %Y-%m-%d] \
		forgotten ""]
	repo_keys_save
}

# The verify seam: sig.verify through the core, never throwing. `datahash` is the
# hash the core itself reported for those bytes when it fetched them, which lets the
# core tell a lost byte apart from a bad signature. Tests stub THIS proc.
proc sig_verify {data sig key principal {datahash ""}} {
	set params [dict create data $data sig $sig key $key principal $principal \
		namespace rio-repository]
	if {$datahash ne ""} { dict set params sha256 $datahash }
	set resp [rio_call sig.verify $params]
	if {![dict get $resp ok]} {
		return [dict create available 0 verified 0 signer "" fingerprint "" \
			reason [dict get $resp error message]]
	}
	return [dict get $resp result]
}

# SHA256SUMS -> {path hash …}. The format `sha256sum` and OpenBSD's `sha256 -r`
# print: a hex digest, whitespace, then the path — with the optional `*` that marks
# a binary-mode hash, and a leading `./` some publishers' `find` leaves behind. A
# line that isn't that shape is skipped: it was signed along with everything else,
# it simply names no file rio will ever fetch.
proc repo_sums_parse {text} {
	set out {}
	foreach line [split $text "\n"] {
		if {![regexp {^([0-9a-fA-F]{64})[ \t]+\*?(.+)$} [string trimright $line "\r"] -> h path]} continue
		set path [string trimleft [string trim $path] "./"]
		if {$path ne ""} { dict set out $path [string tolower $h] }
	}
	return $out
}

# The one-word mark a variant carries in the window: what rio knows about where
# these bytes came from. Deliberately said in all three cases, including the boring
# one — "signed" means nothing to a user who has never seen rio say "unsigned".
proc sig_mark {state} {
	switch -- $state {
		signed     { return "signed" }
		unverified { return "unverified" }
	}
	return "unsigned"
}

# The line above "From:" in the install consent — the same three cases, at the
# length a decision deserves.
proc ext_consent_sig_line {source} {
	set sig [repo_sig_of $source]
	switch -- [dict get $sig state] {
		signed {
			return "Signed by [dict get $sig signer], and every file was checked against that signature."
		}
		unverified {
			return "SIGNED, BUT NOT CHECKED: this repository publishes a signature, and the core's host has no ssh-keygen to check it with. You turned that on in Preferences ▸ Extensions."
		}
	}
	return "NOT SIGNED: nothing vouches for these files. Over plain http, anyone between you and the server could have changed them."
}

# The hash the core reported for a fetch, or "". A core older than D118 answers
# repo.fetch without one however politely it is asked (D30 lets a GUI attach to any
# core), and that is not a detail to discover through a Tcl error mid-scan: it means
# this core cannot check a signature at all, which is the same situation as having no
# ssh-keygen and is handled in the same place.
proc fetch_hash {r} {
	if {[dict exists $r sha256]} { return [dict get $r sha256] }
	return ""
}

proc repo_sig_of {source} {
	if {[dict exists $::repo_sig $source]} { return [dict get $::repo_sig $source] }
	return [dict create state unsigned signer "" sums {}]
}

# Is `path` (relative to the repository root) allowed to be what we just fetched?
# On an unsigned or unverifiable source there is nothing to check against and the
# answer is yes — that is what those words mean. On a SIGNED one, a file rio fetches
# must be in SHA256SUMS with that hash: a file the sums don't mention is as bad as
# one whose hash differs, because a publisher's SHA256SUMS covers everything served.
proc repo_file_ok {source path hash} {
	set sig [repo_sig_of $source]
	if {[dict get $sig state] ne "signed"} { return 1 }
	if {$hash eq ""} { return 0 }   ;# asked for, not answered: check nothing, trust nothing
	set sums [dict get $sig sums]
	if {![dict exists $sums $path]} { return 0 }
	return [expr {[string tolower $hash] eq [dict get $sums $path]}]
}

# Decide what a source's signature says, BEFORE anything else is fetched from it.
# `markerhash` is the hash of the rio-repository.conf we already have, checked here
# against the sums it must itself be listed in.
#
# Returns {ok 1 state … signer … sums …} or {ok 0 code … error … ?key …?}. Every
# refusal is the WHOLE source: a signed repository is signed as one thing, and
# "most of it verified" is not a state a user can act on.
# "This signature cannot be checked here" — no ssh-keygen, one too old, a core that
# can't hash, or a core that doesn't know sig.verify at all. NOT the same as a
# signature that failed, and never allowed to become it.
#
# A source nobody has trusted yet loses nothing by listing as unsigned: rio was not
# going to check anything for it either way. One whose key IS trusted would lose the
# whole point of having trusted it, so it is refused — unless the user turned the
# switch on, and then it lists loudly as `unverified`.
proc _sig_cant_check {trusted why} {
	if {$trusted eq ""} {
		return [dict create ok 1 state unsigned signer "" sums {}]
	}
	if {$::repo_allow_unverified} {
		return [dict create ok 1 state unverified signer "" sums {}]
	}
	return [dict create ok 0 code sig_no_tool \
		error "rio can't check this repository's signature: $why. Fix that on the core's host — openssh 8.0 or newer, and a rio core new enough to hash what it fetches — or, to use the repository unchecked, turn on Preferences ▸ Extensions ▸ \"Use repositories rio can't check\"."]
}

proc repo_sig_check {base pubkey markerhash} {
	set trusted [repo_key_of $base]
	if {$pubkey eq "" && $trusted eq ""} {
		return [dict create ok 1 state unsigned signer "" sums {}]
	}
	# No downgrade (D118): a repository that was signed and now isn't is refused,
	# because that is exactly what removing a signature would look like.
	if {$pubkey eq ""} {
		return [dict create ok 0 code sig_dropped \
			error "This repository used to be signed and no longer publishes a key. rio won't quietly stop checking: if the publisher really dropped signing, delete its section from repository-keys.conf."]
	}
	if {$trusted ne "" && $pubkey ne $trusted} {
		return [dict create ok 0 code key_changed key $pubkey \
			error "This repository is now signed by a DIFFERENT key than the one rio trusted. That is what a key rotation looks like — and also what someone impersonating the repository looks like. Review the new key before trusting it."]
	}
	set sr [repo_fetch $base/SHA256SUMS 1]
	set gr [repo_fetch $base/SHA256SUMS.sig]
	set have [expr {[dict get $sr ok] && [dict get $sr status] == 200
		&& [dict get $gr ok] && [dict get $gr status] == 200}]
	if {!$have} {
		if {$trusted eq ""} {
			# Nothing was trusted here yet and there is no signature to trust: the
			# publisher announced a key and published nothing to check with it.
			return [dict create ok 1 state unsigned signer "" sums {}]
		}
		return [dict create ok 0 code sig_missing \
			error "This repository is signed, but SHA256SUMS or SHA256SUMS.sig couldn't be fetched from it. A publish that uploaded the payloads and not the signature looks exactly like this."]
	}
	# A core older than D118 hashes nothing, however it is asked: no hash, no way to
	# check a single file even if the signature itself verified. Same situation as no
	# ssh-keygen, so the same answer — and found HERE, rather than as a Tcl error at
	# the first file compared.
	if {$markerhash eq "" || [fetch_hash $sr] eq ""} {
		return [_sig_cant_check $trusted \
			"the core this GUI is attached to is older than rio's repository signing and can't hash what it fetches"]
	}
	set v [sig_verify [dict get $sr text] [dict get $gr text] $pubkey $base [fetch_hash $sr]]
	if {![dict get $v available]} {
		return [_sig_cant_check $trusted [dict get $v reason]]
	}
	if {![dict get $v verified]} {
		return [dict create ok 0 code sig_bad \
			error "The signature on this repository doesn't verify: [dict get $v reason]. Until it does, rio won't install anything from it — the files may have been altered after they were published."]
	}
	set sums [repo_sums_parse [dict get $sr text]]
	# The marker carried the key, so it must be covered by the sums it pointed at —
	# checked AFTER verification, and before the key is trusted for the first time.
	if {![dict exists $sums rio-repository.conf]
			|| [dict get $sums rio-repository.conf] ne [string tolower $markerhash]} {
		return [dict create ok 0 code hash_mismatch \
			error "The signature verifies, but rio-repository.conf isn't the file it vouches for. The repository's SHA256SUMS is out of date, or these files are not the ones that were signed."]
	}
	# First sight (D119). The signature verifies and the marker is the file it vouches
	# for — so there IS a key worth confirming, and rio can show a fingerprint that
	# means something. It still refuses until the user says yes, the way ssh does:
	# recording it here would hand a first-scan impostor a permanent trust decision the
	# user never took, and rio would then defend that key faithfully forever.
	if {$trusted eq ""} {
		return [dict create ok 0 code key_unconfirmed key $pubkey \
			error "This repository signs with a key rio has never been told to trust. Nothing is installed or listed from it until you confirm that key — review its fingerprint, and check it against the publisher's own page before you accept."]
	}
	return [dict create ok 1 state signed signer [dict get $v signer] sums $sums]
}

# --- the provenance ledger ----------------------------------------------------
proc ledger_path {} {
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else { return "" }
	return [file join $base rio extensions.json]
}

# Machine-written JSON: {"kind/name": {source, dir, version, installed,
# files:[…], ?anysource?}, …}. Corrupt or missing -> an empty ledger, never fatal
# — the worst outcome is "rio forgot where an extension came from", not a crash.
# `anysource` (D107) is NOT in the required set: it arrived later, and every
# ledger written before it must keep loading. Absent means 0.
proc ledger_load {} {
	set ::ext_ledger {}
	set path [ledger_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {
		set d [json::json2dict [slurp_utf8 $path]]
		dict for {key e} $d {
			foreach k {source dir version files installed} {
				if {![dict exists $e $k]} { error "entry $key missing $k" }
			}
		}
		set ::ext_ledger $d
	}]} { set ::ext_ledger {} }
}

proc ledger_entry_json {e} {
	set parts {}
	foreach k {source dir version installed} {
		lappend parts "[rio::wire::str $k]:[rio::wire::str [dict get $e $k]]"
	}
	lappend parts "\"files\":[rio::wire::strarr [dict get $e files]]"
	# Written only when SET, so an untouched ledger keeps its pre-D107 shape.
	if {[dict exists $e anysource] && [dict get $e anysource]} {
		lappend parts "\"anysource\":\"1\""
	}
	# The key that vouched for these files, when there was one (D118) — same rule.
	if {[dict exists $e signed_by] && [dict get $e signed_by] ne ""} {
		lappend parts "\"signed_by\":[rio::wire::str [dict get $e signed_by]]"
	}
	return "{[join $parts ,]}"
}

proc ledger_save {} {
	set path [ledger_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::objmap $::ext_ledger ledger_entry_json]
		close $f
	}
}

# --- fetching & scanning ------------------------------------------------------

# The one fetch seam: repo.fetch through the core, never throwing — the return
# is {ok 1 status <n> text <t> ?sha256 <hex>?} or {ok 0 error <msg> code <code>}.
# `code` is the taxonomy's (D11) — untrusted_cert is the one the window acts on
# (D111). `hash` asks the core for the hash of the bytes it received (D118), which
# is the only place that hash can honestly be taken: the text here has been decoded
# and re-encoded on its way through the wire. Tests stub THIS proc with a fixture
# table (no network in tests, D39).
proc repo_fetch {url {hash 0}} {
	set params [dict create url $url]
	if {$hash} { dict set params sha256 1 }
	set resp [rio_call repo.fetch $params]
	if {[dict get $resp ok]} {
		set out [dict create ok 1 status [dict get $resp result status] \
			text [dict get $resp result text]]
		if {[dict exists $resp result sha256]} {
			dict set out sha256 [dict get $resp result sha256]
		}
		return $out
	}
	return [dict create ok 0 error [dict get $resp error message] \
		code [dict get $resp error code]]
}

# The `index` file: one extension-subdir name per line, # comments. A line
# that fails the safe-name rule is skipped, not fatal — one bad entry must not
# hide the rest of a repository.
proc repo_parse_index {text} {
	set dirs {}
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {[ext_safe_name $t] && $t ni $dirs} { lappend dirs $t }
	}
	return $dirs
}

# The autoindex fallback: when a repository omits `index`, the server's own
# directory listing stands in. One tolerant pass — every href ending in "/"
# whose name passes the safe-name rule is a candidate subdirectory; that one
# filter drops ../, absolute URLs, query links (Apache's ?C=N;O=D), and any
# percent-encoded name in a single stroke. Verified against canned Apache,
# nginx, and OpenBSD-httpd listings in the test suite.
proc repo_parse_autoindex {html} {
	set dirs {}
	foreach {m name} [regexp -all -inline -nocase {href="([^"]+)/"} $html] {
		if {[ext_safe_name $name] && $name ni $dirs} { lappend dirs $name }
	}
	return $dirs
}

# Scan ONE source: the marker manifest (required — anything without a parseable
# rio-repository.conf carrying name= is "not a rio repository"), then its signature
# if it has one (D118), then the extension list (index, else autoindex), then each
# extension's manifest.
# Returns {ok 1 name <n> description <d> sig <state> signer <fp> sums {…}
# exts {<variant>…}} or {ok 0 error <e> ?code <c>?}; a malformed extension manifest
# skips that extension, never the source — but a file that fails its signed hash
# takes the whole source down, because a signed repository is signed as one thing.
# A variant dict: {source dir name kind version author description files sig signer}.
proc repo_source_scan {base} {
	set base [string trimright $base /]
	set r [repo_fetch $base/rio-repository.conf 1]
	if {![dict get $r ok]} {
		return [dict create ok 0 error [dict get $r error] \
			code [expr {[dict exists $r code] ? [dict get $r code] : ""}]]
	}
	if {[dict get $r status] != 200
			|| [catch {rio::conf::parse [dict get $r text]} conf]
			|| ![dict exists $conf "" name]} {
		return [dict create ok 0 error "not a rio repository (no usable rio-repository.conf)"]
	}
	set srcname [dict get $conf "" name]
	set srcdesc [expr {[dict exists $conf "" description] ? [dict get $conf "" description] : ""}]
	# What this source's signature says, before a single payload is considered. The
	# answer is recorded in ::repo_sig FIRST, because repo_file_ok reads it there for
	# every file fetched below.
	set sig [repo_sig_check $base \
		[expr {[dict exists $conf "" key] ? [string trim [dict get $conf "" key]] : ""}] \
		[expr {[dict exists $r sha256] ? [dict get $r sha256] : ""}]]
	if {![dict get $sig ok]} {
		dict unset ::repo_sig $base
		return [dict create ok 0 error [dict get $sig error] code [dict get $sig code] \
			newkey [expr {[dict exists $sig key] ? [dict get $sig key] : ""}]]
	}
	dict set ::repo_sig $base [dict create state [dict get $sig state] \
		signer [dict get $sig signer] sums [dict get $sig sums]]
	set signed [expr {[dict get $sig state] eq "signed"}]
	set dirs {}
	set ir [repo_fetch $base/index $signed]
	if {[dict get $ir ok] && [dict get $ir status] == 200} {
		if {$signed && ![repo_file_ok $base index [fetch_hash $ir]]} {
			return [repo_hash_refusal $base index]
		}
		set dirs [repo_parse_index [dict get $ir text]]
	} else {
		# The autoindex is the SERVER's own listing, not a file of the repository, so
		# there is nothing it could be checked against. It costs nothing: every
		# directory it names still has to produce a manifest the sums vouch for.
		set ar [repo_fetch $base/]
		if {[dict get $ar ok] && [dict get $ar status] == 200} {
			set dirs [repo_parse_autoindex [dict get $ar text]]
		}
	}
	set exts {}
	foreach d $dirs {
		set mr [repo_fetch $base/$d/rio-extension.conf $signed]
		if {![dict get $mr ok] || [dict get $mr status] != 200} continue
		if {$signed && ![repo_file_ok $base $d/rio-extension.conf [fetch_hash $mr]]} {
			return [repo_hash_refusal $base $d/rio-extension.conf]
		}
		if {[catch {rio::conf::parse [dict get $mr text]} mc]} continue
		set top [expr {[dict exists $mc ""] ? [dict get $mc ""] : {}}]
		set ok 1
		foreach k {name kind version files} {
			if {![dict exists $top $k]} { set ok 0 }
		}
		if {!$ok} continue
		set name [dict get $top name]
		set kind [dict get $top kind]
		if {![ext_safe_name $name] || ![ext_safe_name $kind]} continue
		set files {}
		foreach f [split [dict get $top files]] {
			if {$f eq ""} continue
			if {![ext_safe_name $f]} { set ok 0 ; break }
			lappend files $f
		}
		if {!$ok || ![llength $files]} continue
		set variant [dict create \
			source $base dir $d name $name kind $kind \
			sig [dict get $sig state] signer [dict get $sig signer] \
			version [dict get $top version] \
			author [expr {[dict exists $top author] ? [dict get $top author] : "unknown"}] \
			description [expr {[dict exists $top description] ? [dict get $top description] : ""}] \
			files $files manifest [dict get $mr text]]
		# A kind whose surface carries a VERSIONED contract declares which level it
		# needs, and is greyed when that is past what this rio implements (D66, D123).
		# ext_kind_api knows the manifest key and the ceiling per kind; a kind with no
		# contract (syntax, theme) sets nothing and is never too new.
		set contract [ext_kind_api $kind]
		if {$contract ne ""} {
			lassign $contract key ceiling dflt
			set api [expr {[dict exists $top $key] ? [dict get $top $key] : $dflt}]
			dict set variant api $api
			dict set variant too_new [expr {
				![string is integer -strict $api] || $api > $ceiling}]
		}
		# A provider (D66) installs CORE-side and is sourced into the core, so unlike
		# every other kind it names the one file the core will source.
		if {$kind eq "provider"} {
			dict set variant entry [expr {[dict exists $top entry] ? [dict get $top entry] : ""}]
		}
		lappend exts $variant
	}
	return [dict create ok 1 name $srcname description $srcdesc exts $exts \
		sig [dict get $sig state] signer [dict get $sig signer]]
}

# One wording for "this file is not the file the signature vouches for", wherever it
# is found. It names the file, because "the repository changed" is not actionable and
# "vi/vi.tcl isn't what was signed" is.
proc repo_hash_refusal {base path} {
	dict unset ::repo_sig $base
	return [dict create ok 0 code hash_mismatch \
		error "$path is not the file this repository's signature vouches for. Either it was changed after SHA256SUMS was signed — an upload that didn't re-sign looks like this — or it was changed in transit."]
}

# Scan every configured source into ::repo_variants / ::repo_dead /
# ::repo_srcinfo. A dead source is one honest row, never a failed scan.
# `progress` (optional command prefix) is told each source URL as it starts —
# the Extensions window's status line.
proc repo_scan_all {{progress ""}} {
	set ::repo_variants {}
	set ::repo_dead {}
	set ::repo_srcinfo {}
	set ::repo_sig {}
	repo_keys_load   ;# the file is hand-editable (D118), so re-read it per scan
	set srcs [sources_load]
	set n 0
	foreach src $srcs {
		incr n
		if {$progress ne ""} { {*}$progress $src $n [llength $srcs] }
		set s [repo_source_scan $src]
		if {![dict get $s ok]} {
			lappend ::repo_dead [list $src [dict get $s error] \
				[expr {[dict exists $s code] ? [dict get $s code] : ""}] \
				[expr {[dict exists $s newkey] ? [dict get $s newkey] : ""}]]
			continue
		}
		dict set ::repo_srcinfo $src [dict create \
			name [dict get $s name] description [dict get $s description]]
		foreach v [dict get $s exts] { lappend ::repo_variants $v }
	}
	ext_installed_compute
	ext_updates_compute
}

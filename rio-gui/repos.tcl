# rio-gui/repos.tcl — extension repositories: sources, signatures, the ledger, scanning.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Extension repositories (D39): apt's sources model over plain HTTP.
#
#   sources.list            base URLs, one per line
#   <base>/rio-repository.conf    the marker: name, description, ?key?
#   <base>/index                  optional: one extension dir per line
#   <base>/SHA256SUMS, .sig       optional: the signature (D118)
#   <base>/<dir>/rio-extension.conf   an extension's manifest
#   <base>/<dir>/<files>              its payload
#
# - No central index, no accounts. A local ledger records where each
#   installed extension came from. The same name from two sources is two
#   rows; the user chooses.
# - The core fetches (repo.fetch) and stores themes and providers. The GUI
#   parses manifests (data, never executed), asks consent, installs syntax
#   and mode payloads into its own dirs, and keeps the ledger.
# - The ledger is this GUI's: a second frontend on the same core does not see
#   it (ROADMAP).
# - Every name a repository supplies (dir, name, kind, payload file) must
#   pass ext_safe_name before it joins a URL or a path. No traversal.
# ---------------------------------------------------------------------------

set ::ext_ledger {}     ;# "kind/name" -> {source dir version files installed ?anysource?} (ledger_load)
set ::provider_api_max 4 ;# highest provider-api the core loads (provider.list; D66)
# The highest mode-api this GUI implements (D123, modes/registry.tcl). A
# literal: a mode is sourced into the frontend, so the GUI knows its ceiling.
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
# An extension version is semver (D107), with one allowance: 1 to 3 numeric
# components, missing ones zero.
#
#   1.1           -> {core {1 1 0} pre {}}
#   1.0.0-beta.2  -> {core {1 0 0} pre {beta 2}}
#   1.2.3+build   -> {core {1 2 3} pre {}}      build metadata is ignored
#   2026-07-17    -> ""                         not a version
#
# "" means no claim: such an extension lists and installs, and never shows as
# an update.
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
	# A pre-release needs all three components, or `2026-07-17` would parse
	# as 2026.0.0-07-17.
	if {[llength $pre] && [llength $parts] != 3} { return "" }
	set core {}
	foreach p $parts {
		# Digits only: `string is integer` would accept 0x10 and a sign.
		if {![regexp {^[0-9]+$} $p]} { return "" }
		lappend core [scan $p %d]   ;# scan, not expr: 010 is ten, not an octal error
	}
	while {[llength $core] < 3} { lappend core 0 }
	return [dict create core $core pre $pre]
}

# Compare two version strings: -1, 0, 1, or "" when either does not parse.
# "" is not equality.
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
		# The shorter list is padded with "": fewer identifiers rank lower
		# (1.0.0-alpha < 1.0.0-alpha.1).
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

# One base URL per line; `#` starts a comment.
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

# rio's own repository (D39). Written to sources.list only when that file
# does not exist yet, so a user who removes it is not given it back.
# No trailing slash.
set ::default_repo "http://rio.skylm.org/extensions"
proc sources_seed_default {} {
	set path [sources_path]
	if {$path eq "" || [file exists $path]} return
	sources_save [list $::default_repo]
}

# --- signing: which key speaks for a repository (D118, D119) ---------
#
# Over plain http anyone on the path can rewrite a payload. So a publisher
# signs one root SHA256SUMS with an ssh key. rio checks that signature, then
# every file it fetches against those hashes.
#
# A key is trusted when the user says so (D119), as ssh does:
#
#   first scan, signature verifies   refused as key_unconfirmed; the user
#                                    is shown the fingerprint
#   the user confirms                that key speaks for that source
#   later, another key               refused as key_changed
#   rio's own repository             its key is trusted from the start
#
# Limit: an attacker on the path at the very first scan can offer their own
# key. They then need a human to accept a fingerprint the publisher's page
# contradicts.
#
# The keys are kept by the GUI, beside sources.list. The core verifies
# (sig.verify): ssh-keygen is on its host.

set ::repo_keys {}   ;# scheme-less source -> {key <type+base64> trusted <date> forgotten <date>}
set ::repo_sig  {}   ;# source -> {state signed|unsigned|unverified signer <fp> sums {path hash …}}

# May a repository rio cannot check be used anyway? Off by default. On: a
# source with a trusted key, on a core without a usable ssh-keygen, lists and
# installs, marked `unverified`. A bad signature, a changed key and a wrong
# hash are refused whatever this says.
set ::repo_allow_unverified 0   ;# the preference (prefs.json `allow_unverified_repos`)

# The key rio trusts for its own repository. Published as the `key =` line of
# http://rio.skylm.org/extensions/rio-repository.conf. Fingerprint:
# SHA256:ThigJDQbjz1G8yvZMJ7grlLlcOA6uS+ZDWvJdJPVfG0
# A stored entry wins over this.
set ::default_repo_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOzSB7e8mVA9R+JndUZAIliRW2sxKlUD5P4AMoZuIzLV"

proc repo_keys_path {} {
	set p [sources_path]
	if {$p eq ""} { return "" }
	return [file join [file dirname $p] repository-keys.conf]
}

# repository-keys.conf (D21 format, hand-editable):
#
#   [rio.skylm.org/extensions]
#   key = ssh-ed25519 AAAA…
#   trusted = 2026-09-19
#
# Deleting a section forgets the key. A section without `key` (D119) means:
# trust no key here. Only so can the built-in key be withdrawn.
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

# The key trusted for a source, or "". The scheme is ignored: http to https
# is the same publisher (D109). A stored section without a key answers "",
# and the built-in key is not reached (D119).
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

# sig.verify through the core; never raises. `datahash` is the hash the core
# reported when it fetched the data. Tests stub this proc.
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

# SHA256SUMS -> {path hash …}. The format of `sha256sum` and of OpenBSD's
# `sha256 -r`:
#   <64 hex>  vi/vi.tcl        also  <64 hex> *./vi/vi.tcl
# Any other line is skipped.
proc repo_sums_parse {text} {
	set out {}
	foreach line [split $text "\n"] {
		if {![regexp {^([0-9a-fA-F]{64})[ \t]+\*?(.+)$} [string trimright $line "\r"] -> h path]} continue
		set path [string trimleft [string trim $path] "./"]
		if {$path ne ""} { dict set out $path [string tolower $h] }
	}
	return $out
}

# The one-word mark a variant shows in the window. Said in all three cases.
proc sig_mark {state} {
	switch -- $state {
		signed     { return "signed" }
		unverified { return "unverified" }
	}
	return "unsigned"
}

# The same three cases as a sentence, for the install consent.
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

# The hash the core reported for a fetch, or "". A core older than D118
# reports none; that is handled like a core without ssh-keygen.
proc fetch_hash {r} {
	if {[dict exists $r sha256]} { return [dict get $r sha256] }
	return ""
}

proc repo_sig_of {source} {
	if {[dict exists $::repo_sig $source]} { return [dict get $::repo_sig $source] }
	return [dict create state unsigned signer "" sums {}]
}

# May the file just fetched be `path` (relative to the repository root)? On
# an unsigned or unverified source: yes, there is nothing to check. On a
# signed one it must be in SHA256SUMS with that hash; a file the sums do not
# list is refused too.
proc repo_file_ok {source path hash} {
	set sig [repo_sig_of $source]
	if {[dict get $sig state] ne "signed"} { return 1 }
	if {$hash eq ""} { return 0 }   ;# asked for, not answered: check nothing, trust nothing
	set sums [dict get $sig sums]
	if {![dict exists $sums $path]} { return 0 }
	return [expr {[string tolower $hash] eq [dict get $sums $path]}]
}

# The signature cannot be checked here: no ssh-keygen, one too old, or a core
# that cannot hash. Not a failed signature.
#   no key trusted yet        list as unsigned: nothing would be checked anyway
#   key trusted, switch off   refuse (sig_no_tool)
#   key trusted, switch on    list as unverified
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

# Decide what a source's signature says, before anything else is fetched from
# it. `markerhash` is the hash of its rio-repository.conf, which must be
# listed in the sums too.
# Returns {ok 1 state … signer … sums …} or {ok 0 code … error … ?key …?}.
# A refusal is for the whole source: a repository is signed as one thing.
proc repo_sig_check {base pubkey markerhash} {
	set trusted [repo_key_of $base]
	if {$pubkey eq "" && $trusted eq ""} {
		return [dict create ok 1 state unsigned signer "" sums {}]
	}
	# No downgrade (D118): a repository that was signed and no longer is, is
	# refused.
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
			# A key is announced, but there is no signature and none was trusted.
			return [dict create ok 1 state unsigned signer "" sums {}]
		}
		return [dict create ok 0 code sig_missing \
			error "This repository is signed, but SHA256SUMS or SHA256SUMS.sig couldn't be fetched from it. A publish that uploaded the payloads and not the signature looks exactly like this."]
	}
	# A core older than D118 reports no hash, so no file could be checked.
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
	# The marker carried the key, so the sums must cover the marker. Checked
	# after verification and before the key is first trusted.
	if {![dict exists $sums rio-repository.conf]
			|| [dict get $sums rio-repository.conf] ne [string tolower $markerhash]} {
		return [dict create ok 0 code hash_mismatch \
			error "The signature verifies, but rio-repository.conf isn't the file it vouches for. The repository's SHA256SUMS is out of date, or these files are not the ones that were signed."]
	}
	# First sight (D119): the signature verifies, and still the source is
	# refused until the user confirms the key. Recording it here would let a
	# first-scan impostor be trusted for good.
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

# JSON: {"kind/name": {source, dir, version, installed, files:[…],
# ?anysource?, ?signed_by?}, …}. A corrupt or missing file gives an empty
# ledger. `anysource` (D107) and `signed_by` (D118) are optional.
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
	# The optional keys are written only when set.
	if {[dict exists $e anysource] && [dict get $e anysource]} {
		lappend parts "\"anysource\":\"1\""
	}
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

# repo.fetch through the core; never raises. Returns
# {ok 1 status <n> text <t> ?sha256 <hex>?} or {ok 0 error <msg> code <code>}.
# `hash` asks the core for the hash of the bytes it received (D118); the text
# here has been decoded. Tests stub this proc: no network in tests (D39).
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

# The `index` file: one extension dir per line, `#` comments. An unsafe name
# is skipped.
proc repo_parse_index {text} {
	set dirs {}
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {[ext_safe_name $t] && $t ni $dirs} { lappend dirs $t }
	}
	return $dirs
}

# Without an `index`, the server's directory listing stands in: every href
# ending in "/" whose name is safe. That drops ../, absolute URLs, query
# links and percent-encoded names.
proc repo_parse_autoindex {html} {
	set dirs {}
	foreach {m name} [regexp -all -inline -nocase {href="([^"]+)/"} $html] {
		if {[ext_safe_name $name] && $name ni $dirs} { lappend dirs $name }
	}
	return $dirs
}

# Scan one source: the marker (required, with `name`), its signature (D118),
# the extension list (index, else autoindex), each extension's manifest.
# Returns {ok 1 name <n> description <d> sig <state> signer <fp> exts {<variant>…}}
# or {ok 0 error <e> ?code <c>?}.
# - A malformed manifest skips that extension.
# - A file that fails its signed hash refuses the whole source.
# A variant: {source dir name kind version author description files manifest
# sig signer ?api too_new? ?entry?}.
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
	# The signature first. Its verdict goes into ::repo_sig, where
	# repo_file_ok reads it for every file fetched below.
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
		# The listing is the server's, so no hash covers it. Every directory
		# it names must still yield a manifest the sums cover.
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
		# A kind with a versioned contract (provider, mode) declares the level
		# it needs. Past this rio's ceiling it is `too_new` (D66, D123).
		set contract [ext_kind_api $kind]
		if {$contract ne ""} {
			lassign $contract key ceiling dflt
			set api [expr {[dict exists $top $key] ? [dict get $top $key] : $dflt}]
			dict set variant api $api
			dict set variant too_new [expr {
				![string is integer -strict $api] || $api > $ceiling}]
		}
		# A provider names the file the core will source (D66).
		if {$kind eq "provider"} {
			dict set variant entry [expr {[dict exists $top entry] ? [dict get $top entry] : ""}]
		}
		lappend exts $variant
	}
	return [dict create ok 1 name $srcname description $srcdesc exts $exts \
		sig [dict get $sig state] signer [dict get $sig signer]]
}

# The refusal for a file that fails its signed hash. It names the file.
proc repo_hash_refusal {base path} {
	dict unset ::repo_sig $base
	return [dict create ok 0 code hash_mismatch \
		error "$path is not the file this repository's signature vouches for. Either it was changed after SHA256SUMS was signed — an upload that didn't re-sign looks like this — or it was changed in transit."]
}

# Scan every source into ::repo_variants, ::repo_dead and ::repo_srcinfo. A
# dead source is one row, not a failed scan. `progress`, a command prefix, is
# called as each source starts.
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

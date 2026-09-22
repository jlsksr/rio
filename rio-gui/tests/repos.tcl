#!/usr/bin/env wish
#
# Headless extension-repositories test for rio-gui (AGENTS.md D39): the format
# parsers (index, autoindex listings, manifests), source scanning with dead and
# malformed sources, the consent flow, install/replace/remove end-to-end for
# all three v1 kinds (syntax through the real registry, mode through the modes
# registry, theme through the real core's theme.put/delete), the flat-dir
# collision refusal, the unknown-kind refusal, and the ledger + sources.list
# round-trips. NO network anywhere: the GUI-side fetch seam (repo_fetch) is
# replaced by an in-memory url -> {status text} fixture table; a url absent
# from the table simulates an unreachable host. tk_messageBox is stubbed with
# an answer queue. Needs a DISPLAY (Tk); shows no window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/repos.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this
# file's own non-ASCII expectations arrive mojibake and fail against the correctly-
# decoded values the GUI produces. The same guard the rio-gui and server entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
set ::connect_to "127.0.0.1:$::port"
set argv {}
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}

# --- the fetch stub and the dialog stub ----------------------------------------
# repo_fetch is THE seam (its header says tests replace it): serve from ::fix.
array set ::fix {}
set ::fetches 0        ;# every fetch the GUI asks for — the start-up check must make NONE
                       ;# while its preference is off (D107)
array set ::fixerr {}  ;# url -> {code message}: a fetch the core refused with that code
# The hash is the CORE's answer about the bytes it received (D118), so the stub
# computes a real one over the fixture's own bytes — a fixture whose text changes
# then changes its hash, exactly as a repository would.
package require sha256
proc fix_hash {text} { return [::sha2::sha256 -hex [encoding convertto utf-8 $text]] }
proc repo_fetch {url {hash 0}} {
	incr ::fetches
	if {[info exists ::fixerr($url)]} {
		lassign $::fixerr($url) code msg
		return [dict create ok 0 error $msg code $code]
	}
	if {[info exists ::fix($url)]} {
		lassign $::fix($url) status text
		set out [dict create ok 1 status $status text $text]
		if {$hash} { dict set out sha256 [fix_hash $text] }
		return $out
	}
	return [dict create ok 0 error "connection refused (stub)"]
}

# --- the signature seam (D118) -------------------------------------------------
# sig_verify is what the GUI suite stubs: the crypto itself is the core's, tested
# against real fixtures in rio-core/tests/sig.test. Here a "signature" is the string
# "signed-by:<key>", so the stub can answer the way ssh-keygen would — good for the
# key that made it, bad for any other — without an ssh-keygen anywhere near this file.
set ::sig_available 1     ;# 0 = no ssh-keygen on the core's host
set ::sig_calls {}        ;# every {data-first-line key principal} asked about
proc sig_sign {key} { return "signed-by:$key" }
proc sig_fingerprint {key} {
	if {!$::sig_available} { return "" }
	return "SHA256:fp-of-[string range [lindex $key 1] 0 7]"
}
proc sig_verify {data sig key principal {datahash ""}} {
	lappend ::sig_calls [list [lindex [split $data "\n"] 0] $key $principal]
	if {!$::sig_available} {
		return [dict create available 0 verified 0 signer "" fingerprint "" \
			reason "ssh-keygen isn't installed on the core's host, so rio can't check any signature"]
	}
	if {$datahash ne "" && $datahash ne [fix_hash $data]} {
		return [dict create available 1 verified 0 signer "" fingerprint [sig_fingerprint $key] \
			reason "the signed bytes couldn't be reconstructed here"]
	}
	if {$sig ne [sig_sign $key]} {
		return [dict create available 1 verified 0 signer "" fingerprint [sig_fingerprint $key] \
			reason "signature verification failed: incorrect signature"]
	}
	return [dict create available 1 verified 1 signer [sig_fingerprint $key] \
		fingerprint [sig_fingerprint $key] reason ""]
}

# Give a fixture repository a SHA256SUMS over the files it serves, signed by `key`.
# `paths` are repository-relative, as a publisher's sha256sum writes them.
proc fix_sign {base key paths} {
	set lines {}
	foreach p $paths {
		if {![info exists ::fix($base/$p)]} { error "fix_sign: no fixture for $base/$p" }
		lappend lines "[fix_hash [lindex $::fix($base/$p) 1]]  $p"
	}
	set sums "[join $lines \n]\n"
	set ::fix($base/SHA256SUMS) [list 200 $sums]
	set ::fix($base/SHA256SUMS.sig) [list 200 [sig_sign $key]]
}

# tk_messageBox: consume queued answers (consent dialogs), default `ok`
# (report_error). Every message is logged for asserting on wording.
set ::mb_answers {}
set ::mb_log {}
rename tk_messageBox _real_tk_messageBox
proc tk_messageBox {args} {
	foreach {k v} $args { if {$k eq "-message"} { lappend ::mb_log $v } }
	if {[llength $::mb_answers]} {
		set a [lindex $::mb_answers 0]
		set ::mb_answers [lrange $::mb_answers 1 end]
		return $a
	}
	return ok
}
proc mb_last {} { return [lindex $::mb_log end] }

# --- fixture repositories -------------------------------------------------------
set A http://a.example/exts
set B http://b.example/repo

set zz_scanner {namespace eval rio::syntax::zz {}
proc rio::syntax::zz::scan {line state param} {
	set spans {}
	set i [string first zig $line]
	if {$i >= 0} { lappend spans $i [expr {$i + 3}] keyword }
	return [list $spans {} {}]
}
rio::syntax::register ZZ {zz} rio::syntax::zz::scan}

set zz_scanner_v2 [string map {ZZ ZZv2} $zz_scanner]

set night_theme "base = solarized-dark\n\[colors\]\neditor.bg = #101018"

set ::fix($A/rio-repository.conf) [list 200 \
	"name = A test repository\ndescription = fixtures\nmaintainer = alice"]
set ::fix($A/index) [list 200 \
	"# fixture index\nzz-syntax\nnight-theme\ndrop-mode\nweird-widget\n../evil\n"]
set ::fix($A/zz-syntax/rio-extension.conf) [list 200 \
	"name = zz\nkind = syntax\nversion = 1.0\nauthor = alice\ndescription = ZZ highlighting\nfiles = zz.tcl\nfuture_key = ignored"]
set ::fix($A/zz-syntax/zz.tcl) [list 200 $zz_scanner]
set ::fix($A/night-theme/rio-extension.conf) [list 200 \
	"name = night\nkind = theme\nversion = 1.0\nauthor = alice\ndescription = a dark theme\nfiles = night.theme"]
set ::fix($A/night-theme/night.theme) [list 200 $night_theme]
set ::fix($A/drop-mode/rio-extension.conf) [list 200 \
	"name = drop\nkind = mode\nversion = 2\nauthor = alice\ndescription = a drop-in mode\nfiles = drop.tcl"]
set ::fix($A/drop-mode/drop.tcl) [list 200 \
	{rio::modes::register drop {Drop Mode} {apply {tag {}}} {apply {tag {}}}}]
set ::fix($A/weird-widget/rio-extension.conf) [list 200 \
	"name = weird\nkind = widget\nversion = 0.1\nauthor = bob\nfiles = weird.tcl"]
set ::fix($A/weird-widget/weird.tcl) [list 200 "# payload of an unknown kind"]

# B has no index file -> the scanner falls back to the server's autoindex.
set ::fix($B/rio-repository.conf) [list 200 "name = B repository\nmaintainer = bob"]
set ::fix($B/) [list 200 {<html><head><title>Index of /repo/</title></head>
<body bgcolor="white"><h1>Index of /repo/</h1><hr><pre><a href="../">../</a>
<a href="zz-syntax/">zz-syntax/</a>
<a href="zz2-syntax/">zz2-syntax/</a>
<a href="notes.txt">notes.txt</a>
</pre><hr></body></html>}]
set ::fix($B/zz-syntax/rio-extension.conf) [list 200 \
	"name = zz\nkind = syntax\nversion = 2.0\nauthor = bob\ndescription = ZZ, improved\nfiles = zz.tcl"]
set ::fix($B/zz-syntax/zz.tcl) [list 200 $zz_scanner_v2]
set ::fix($B/zz2-syntax/rio-extension.conf) [list 200 \
	"name = zz2\nkind = syntax\nversion = 1.0\nauthor = bob\nfiles = zz.tcl"]
set ::fix($B/zz2-syntax/zz.tcl) [list 200 "# collides with zz's payload filename"]

# C answers, but its marker is not parseable conf.
set C http://c.example/bad
set ::fix($C/rio-repository.conf) [list 200 "this line has no equals sign"]
# D serves a 404 where the marker should be.
set D http://d.example/void
set ::fix($D/rio-repository.conf) [list 404 "not found"]
set DEAD http://dead.example/gone

# --- the parsers ---------------------------------------------------------------
ok "safe-name: accepts"      [list [ext_safe_name night] [ext_safe_name my-ext.2]] {1 1}
ok "safe-name: refuses"      [list [ext_safe_name ../evil] [ext_safe_name .hidden] \
	[ext_safe_name "a b"] [ext_safe_name "a%20b"] [ext_safe_name ""]] {0 0 0 0 0}

ok "index: parses, skips comments and unsafe lines" \
	[repo_parse_index "# c\n\nzz-syntax\nnight-theme\n../evil\nzz-syntax\n"] \
	{zz-syntax night-theme}

# Apache 2.4 fancy autoindex: query-sort links, parent, a file entry.
ok "autoindex: apache" [repo_parse_autoindex {<html><head><title>Index of /exts</title></head><body>
<h1>Index of /exts</h1><table>
<tr><th><a href="?C=N;O=D">Name</a></th><th><a href="?C=M;O=A">Last modified</a></th></tr>
<tr><td><a href="/">Parent Directory</a></td></tr>
<tr><td><a href="night-theme/">night-theme/</a></td><td>2026-01-01</td></tr>
<tr><td><a href="zz-syntax/">zz-syntax/</a></td><td>2026-01-02</td></tr>
<tr><td><a href="README">README</a></td></tr>
<tr><td><a href="weird%20name/">weird name/</a></td></tr>
</table></body></html>}] {night-theme zz-syntax}

# nginx autoindex: pre block, ../ parent.
ok "autoindex: nginx" [repo_parse_autoindex [lindex $::fix($B/) 1]] {zz-syntax zz2-syntax}

# OpenBSD httpd directory listing.
ok "autoindex: openbsd httpd" [repo_parse_autoindex {<!DOCTYPE html>
<html><head><title>Index of /rio/</title></head><body><h1>Index of /rio/</h1>
<table><tr><td><a href="../">..</a></td></tr>
<tr><td><a href="night-theme/">night-theme/</a></td><td>1 Jan 2026</td><td>512</td></tr>
<tr><td><a href="index">index</a></td></tr>
</table></body></html>}] {night-theme}

# --- first-run seed (D39) -------------------------------------------------------
# Booting with no sources.list pre-fills rio's own repository, so a fresh install has
# something to browse. It is a true-first-run only act: idempotent while the file exists,
# and it never comes back once the user has emptied the list.
#
# The constant itself has a contract worth holding, since it is edited by hand and a
# bad value is silent: repo_source_scan appends "/rio-repository.conf" to it, so a
# trailing slash would ask every fresh install for ".../extensions//rio-repository.conf".
ok "seed: the default names a scheme"   [regexp {^https?://} $::default_repo] 1
ok "seed: and carries no trailing slash" [string match */ $::default_repo] 0

ok "seed: first run pre-fills rio's repo" [sources_load] [list $::default_repo]
sources_seed_default
ok "seed: idempotent while file exists"   [sources_load] [list $::default_repo]
sources_save {}
sources_seed_default
ok "seed: no re-seed after the file exists" [sources_load] {}

# --- sources.list round-trip ----------------------------------------------------
sources_save [list $A $B $C $D $DEAD]
ok "sources: round-trip" [sources_load] [list $A $B $C $D $DEAD]
ok "sources: file has the header comment" \
	[string match "#*" [lindex [split [::read [set f [open [sources_path] r]]] "\n"] 0]] 1
close $f

# --- scanning everything ---------------------------------------------------------
set ::prog {}
repo_scan_all {apply {{src n total} { lappend ::prog $n/$total }}}
ok "scan: progress told each source"  $::prog {1/5 2/5 3/5 4/5 5/5}
ok "scan: three sources failed honestly" [llength $::repo_dead] 3
set deadurls {}
foreach d $::repo_dead { lappend deadurls [lindex $d 0] }
ok "scan: the failed three"           [lsort $deadurls] [lsort [list $C $D $DEAD]]
ok "scan: malformed marker wording"   \
	[string match "not a rio repository*" [lindex [lsearch -index 0 -inline $::repo_dead $C] 1]] 1
ok "scan: live sources named"         \
	[list [dict get $::repo_srcinfo $A name] [dict get $::repo_srcinfo $B name]] \
	{{A test repository} {B repository}}
ok "scan: six variants found"         [llength $::repo_variants] 6

proc variant {name source} {
	foreach v $::repo_variants {
		if {[dict get $v name] eq $name && [dict get $v source] eq $source} { return $v }
	}
	return ""
}
set vzzA [variant zz $::A]
ok "scan: variant fields"  [list [dict get $vzzA kind] [dict get $vzzA version] \
	[dict get $vzzA author] [dict get $vzzA dir] [dict get $vzzA files]] \
	{syntax 1.0 alice zz-syntax zz.tcl}
ok "scan: unknown kind still listed"  [dict get [variant weird $::A] kind] widget
ok "scan: autoindex source scanned"   [dict get [variant zz $::B] version] 2.0

# --- consent ---------------------------------------------------------------------
ok "install: baseline — no zz scanner" [rio::syntax::for_path x.zz] ""
set ::mb_answers {no}
ok "install: consent 'no' installs nothing" [ext_install $vzzA] 0
ok "install: consent names the code risk" \
	[string match "*Tcl CODE*x.example*" [string map {a.example x.example b.example x.example} [mb_last]]] 1
ok "install: nothing on disk after 'no'" \
	[file exists [file join [hl_user_dir] zz.tcl]] 0

# --- syntax install end-to-end ----------------------------------------------------
set ::mb_answers {yes}
ok "syntax: installs"        [ext_install $vzzA] 1
ok "syntax: file landed"     [file exists [file join [hl_user_dir] zz.tcl]] 1
ok "syntax: scanner live"    [expr {[rio::syntax::for_path x.zz] ne ""}] 1
ok "syntax: language named"  [rio::syntax::lang_for_path x.zz] ZZ
ok "syntax: actually scans"  \
	[rio::syntax::tokenize [rio::syntax::for_path x.zz] "a zig b"] {1.2 1.5 keyword}
set e [dict get $::ext_ledger syntax/zz]
ok "syntax: ledger provenance" \
	[list [dict get $e source] [dict get $e version] [dict get $e files]] \
	[list $::A 1.0 zz.tcl]

# --- theme install end-to-end -----------------------------------------------------
set ::mb_answers {yes}
ok "theme: installs"          [ext_install [variant night $::A]] 1
ok "theme: consent says data" [string match "*never executed*" [mb_last]] 1
set resp [rio_call theme.list {}]
ok "theme: core lists night"  [expr {"night" in [dict get $resp result themes]}] 1
# The picker lists theme.list on open (D92), so an install is live with nothing to refill.
ok "theme: in the picker rows" \
	[expr {[lsearch -exact [lmap r [theme_pick_rows] {lindex $r 0}] night] >= 0}] 1
ok "theme: row carries a label" \
	[expr {[lsearch -exact [lmap r [theme_pick_rows] {lindex $r 1}] Night] >= 0}] 1
do_theme night
ok "theme: applies live"      [rio_real_t cget -background] #101018
ok "theme: is the active one" $::theme_name night

# --- mode install end-to-end ------------------------------------------------------
set ::mb_answers {yes}
ok "mode: installs"          [ext_install [variant drop $::A]] 1
ok "mode: registered"        [rio::modes::exists drop] 1
set found 0
for {set i 0} {$i <= [.m.settings.editmode index end]} {incr i} {
	if {[.m.settings.editmode entrycget $i -label] eq "Drop Mode"} { set found 1 }
}
ok "mode: in the mode menu"  $found 1
ok "mode: active mode kept"  $::editmode_active windows

# --- unknown kind refused ---------------------------------------------------------
set before [llength $::mb_log]
ok "unknown kind: refused"       [ext_install [variant weird $::A]] 0
ok "unknown kind: honest reason" [string match "*needs a newer rio*" [mb_last]] 1
ok "unknown kind: no consent asked" [llength $::mb_log] [expr {$before + 1}]

# --- replace: same name, different source -----------------------------------------
set ::mb_answers {yes}
ok "replace: installs the B variant"  [ext_install [variant zz $::B]] 1
ok "replace: consent names the swap"  \
	[string match "*Replaces the installed 'zz' 1.0 from $::A*" [mb_last]] 1
ok "replace: ledger reprovenanced"    \
	[list [dict get $::ext_ledger syntax/zz source] [dict get $::ext_ledger syntax/zz version]] \
	[list $::B 2.0]
ok "replace: the new code is live"    [rio::syntax::lang_for_path x.zz] ZZv2

# --- flat-dir collision refused ----------------------------------------------------
set ::mb_answers {yes}
ok "collision: refused"        [ext_install [variant zz2 $::B]] 0
ok "collision: names the owner" [string match "*owned by the installed syntax 'zz'*" [mb_last]] 1
ok "collision: zz's file untouched" [rio::syntax::lang_for_path x.zz] ZZv2
ok "collision: no ledger entry" [dict exists $::ext_ledger syntax/zz2] 0

# --- remove -----------------------------------------------------------------------
ok "remove: syntax"           [ext_remove syntax zz] 1
ok "remove: file gone"        [file exists [file join [hl_user_dir] zz.tcl]] 0
ok "remove: scanner gone"     [rio::syntax::for_path x.zz] ""
ok "remove: ledger gone"      [dict exists $::ext_ledger syntax/zz] 0

# removing the ACTIVE theme falls back to default
ok "remove: theme while active" [ext_remove theme night] 1
ok "remove: core no longer lists it" \
	[expr {"night" in [dict get [rio_call theme.list {}] result themes]}] 0
ok "remove: fell back to default" $::theme_name default
ok "remove: default look restored" [rio_real_t cget -background] white

ok "remove: mode"             [ext_remove mode drop] 1
ok "remove: mode unregistered" [rio::modes::exists drop] 0
ok "remove: windows still attached" $::editmode_active windows

# --- ledger persistence ------------------------------------------------------------
set ::mb_answers {yes}
ext_install $vzzA
set saved [dict get $::ext_ledger syntax/zz]
set ::ext_ledger {}
ledger_load
set back [dict get $::ext_ledger syntax/zz]
set same 1
foreach k {source dir version files installed} {
	if {[dict get $back $k] ne [dict get $saved $k]} { set same 0 }
}
ok "ledger: round-trips through JSON" $same 1
set f [open [ledger_path] w] ; puts $f "{this is not json" ; close $f
ledger_load
ok "ledger: corrupt file -> empty, not fatal" $::ext_ledger {}
catch {file delete [file join [hl_user_dir] zz.tcl]}   ;# the corrupt ledger forgot this file
hl_load

# --- the Extensions window ---------------------------------------------------
extensions_window
ok "window: exists, non-modal"     [list [winfo exists .extw] [grab current]] {1 {}}
ok "window: scan done, not busy"   $::repo_busy 0
ok "window: refresh is the ⟳ glyph" [.extw.hdr.refresh cget -text] "⟳"
ok "window: status counts the scan" \
	[string match "6 extension(s) from 2 repositories" [.extw.foot.status cget -text]] 1

proc rowidx {kind name} {
	for {set i 0} {$i < [llength $::extw_rows]} {incr i} {
		set r [lindex $::extw_rows $i]
		if {[dict exists $r key] && [dict get $r key] eq "$kind/$name"} { return $i }
	}
	return -1
}
set i [rowidx syntax zz]
ok "window: same name aggregates"  [string match "*2 sources*" [.extw.body.list get $i]] 1
ok "window: unknown kind labeled"  \
	[string match "*needs a newer rio*" [.extw.body.list get [rowidx widget weird]]] 1
set deadrows 0
foreach r $::extw_rows { if {[dict exists $r dead]} { incr deadrows } }
ok "window: dead sources shown"    $deadrows 3

# selecting the zz row lists BOTH variants with their provenance
.extw.body.list selection clear 0 end
.extw.body.list selection set $i
extw_select
ok "window: variant A line"  [string match "*1.0 by alice — a.example*" [.extw.det.v0.l cget -text]] 1
ok "window: variant B line"  [string match "*2.0 by bob — b.example*"   [.extw.det.v1.l cget -text]] 1
ok "window: both installable" \
	[list [winfo exists .extw.det.v0.in] [winfo exists .extw.det.v1.in]] {1 1}

# install straight from the detail button (variant A)
set ::mb_answers {yes}
.extw.det.v0.in invoke
ok "window: install via button"    [dict get $::ext_ledger syntax/zz source] $::A
ok "window: row shows installed"   \
	[string match "*\[installed\]*" [.extw.body.list get [rowidx syntax zz]]] 1
ok "window: selection survived"    \
	[string match "*\[installed\]*" [.extw.det.v0.mark cget -text]] 1
ok "window: installed row has Remove, other Install" \
	[list [winfo exists .extw.det.v0.rm] [winfo exists .extw.det.v1.in]] {1 1}

# the filter narrows the list
.extw.hdr.filter insert end night
extw_fill
ok "window: filter narrows"        [llength $::extw_rows] 1
ok "window: filtered to night"     [dict get [lindex $::extw_rows 0] name] night
.extw.hdr.filter delete 0 end
extw_fill

# the busy guard disables the action surface (non-modal => re-entry is real)
extw_busy 1
ok "window: busy disables header"  [.extw.hdr.refresh cget -state] disabled
set before [dict get $::ext_ledger syntax/zz version]
extw_install [rowidx syntax zz] 1   ;# must be a no-op while busy
ok "window: busy blocks install"   [dict get $::ext_ledger syntax/zz version] $before
extw_busy 0
ok "window: idle re-enables"       [.extw.hdr.refresh cget -state] normal

# the installed version vanishing from its source is said honestly
sources_save [list $::B]
extw_refresh
.extw.body.list selection set [rowidx syntax zz]
extw_select
ok "window: not-listed-anymore line" \
	[string match "*installed: 1.0*no longer listed*" [.extw.det.inst.l cget -text]] 1
ok "window: it still offers Remove"  [winfo exists .extw.det.inst.rm] 1

# source gone entirely: the row is synthesized from the ledger, Remove works
sources_save {}
extw_refresh
set i [rowidx syntax zz]
ok "window: offline row synthesized" [string match "*(offline)*" [.extw.body.list get $i]] 1
.extw.body.list selection set $i
extw_select
.extw.det.v0.rm invoke
ok "window: offline remove works"   [dict exists $::ext_ledger syntax/zz] 0
ok "window: row gone after remove"  [rowidx syntax zz] -1

# the Repositories… sources editor: add validates, remove removes, both persist
after 100 {
	.extsrc.add.url insert end http://e.example/more
	extw_source_add
	.extsrc.add.url insert end https://e.example/tls
	extw_source_add
	.extsrc.add.url insert end ftp://nope.example/old
	extw_source_add
	set ::src_mid [sources_load]
	.extsrc.body.list selection set 0
	extw_source_remove
	set ::src_after [sources_load]
	destroy .extsrc
}
extw_sources_dialog
ok "sources dialog: http added"     [expr {"http://e.example/more" in $::src_mid}] 1
ok "sources dialog: https added too" [expr {"https://e.example/tls" in $::src_mid}] 1
ok "sources dialog: ftp refused"    [string match "*starts with http:// or https://*ftp://*" [mb_last]] 1
ok "sources dialog: only the two kept" [llength $::src_mid] 2
ok "sources dialog: remove removes" $::src_after {https://e.example/tls}
destroy .extw

# ===================================================================================
# Versions, and updates (AGENTS.md D107)
#
# D39 said a version was an opaque string rio never compares; D107 makes it semver
# and compares it. Everything below is the consequence: what "installed" means, what
# counts as an update (and pointedly what does not — another repository's same-named
# extension), Update All's single consent, and the start-up check that must not touch
# the network until it is asked to.
# ===================================================================================

# --- the comparator ----------------------------------------------------------------
# The lenient half is deliberate: `1.1` must compare, because every version installed
# anywhere predates the rule. The strict half is too: a date stamp is NOT a version,
# and saying so is better than inventing an order for it.
ok "ver: patch order"        [list [ext_ver_cmp 1.0.0 1.0.1] [ext_ver_cmp 1.0.1 1.0.0]] {-1 1}
ok "ver: minor beats patch"  [ext_ver_cmp 1.0.9 1.1.0] -1
ok "ver: major beats minor"  [ext_ver_cmp 1.9.9 2.0.0] -1
ok "ver: numeric, not lexical" [ext_ver_cmp 1.10.0 1.9.0] 1
ok "ver: short form is semver" [list [ext_ver_cmp 1.1 1.1.0] [ext_ver_cmp 1 1.0.0]] {0 0}
ok "ver: short form still orders" [ext_ver_cmp 1.1 1.1.1] -1
ok "ver: pre-release ranks below its release" \
	[list [ext_ver_cmp 1.0.0-beta 1.0.0] [ext_ver_cmp 1.0.0 1.0.0-beta]] {-1 1}
ok "ver: pre-release fields"  [list [ext_ver_cmp 1.0.0-alpha.1 1.0.0-alpha.2] \
	[ext_ver_cmp 1.0.0-alpha.2 1.0.0-alpha.beta] [ext_ver_cmp 1.0.0-alpha 1.0.0-alpha.1]] {-1 -1 -1}
ok "ver: build metadata ignored" [ext_ver_cmp 1.0.0+a 1.0.0+z] 0
ok "ver: dates make no claim"  [ext_ver_cmp 2026-07-17 2026-08-01] ""
ok "ver: junk makes no claim"  [list [ext_ver_cmp v2 1.0.0] [ext_ver_cmp 1.2.3.4 1.0.0] \
	[ext_ver_cmp "" 1.0.0]] {{} {} {}}
ok "ver: parse fills components" [ext_ver_parse 1.1] {core {1 1 0} pre {}}
ok "ver: parse refuses non-digits" [list [ext_ver_parse 1.a.0] [ext_ver_parse 0x2.0.0]] {{} {}}

# --- fixtures for the update cases --------------------------------------------------
# U is "the repository you installed from"; V offers the SAME NAME from somewhere else.
set U http://u.example/repo
set V http://v.example/repo
proc up_manifest {name version} {
	return "name = $name\nkind = syntax\nversion = $version\nauthor = alice\ndescription = updatable\nfiles = $name.tcl"
}
proc up_payload {name} { return "# payload of $name" }
proc up_publish {src name version} {
	set ::fix($src/$name-syntax/rio-extension.conf) [list 200 [up_manifest $name $version]]
	set ::fix($src/$name-syntax/$name.tcl) [list 200 [up_payload $name]]
}
set ::fix($U/rio-repository.conf) [list 200 "name = U repository\nmaintainer = alice"]
set ::fix($U/index) [list 200 "up\nup2\nfresh\n"]
set ::fix($V/rio-repository.conf) [list 200 "name = V repository\nmaintainer = mallory"]
set ::fix($V/index) [list 200 "up\n"]
# The index names dirs, the manifests live under <dir>/ — up_publish spells both.
foreach {n v} {up 1.0.0 up2 1.0.0 fresh 1.0.0} { up_publish $U $n $v }
up_publish $V up 2.0.0
set ::fix($U/index) [list 200 "up-syntax\nup2-syntax\nfresh-syntax\n"]
set ::fix($V/index) [list 200 "up-syntax\n"]

sources_save [list $U]
repo_scan_all
ok "updates: three offered by U"   [llength $::repo_variants] 3
set ::mb_answers {yes}
ok "updates: install the 1.0.0"    [ext_install [variant up $::U]] 1
ok "updates: nothing pending yet"  [dict size $::ext_updates] 0
ok "updates: installed view knows it" \
	[dict get $::ext_installed syntax/up] [dict create version 1.0.0 source $::U]

# --- the publisher ships a new version ----------------------------------------------
up_publish $U up 1.1.0
repo_scan_all
ok "updates: one pending"          [dict size $::ext_updates] 1
ok "updates: from and to"          [list [dict get $::ext_updates syntax/up from] \
	[dict get $::ext_updates syntax/up to]] {1.0.0 1.1.0}
ok "updates: uninstalled is not an update" [dict exists $::ext_updates syntax/fresh] 0

# A source that goes BACKWARDS is not an update — a downgrade stays possible, by hand.
up_publish $U up 0.9.0
repo_scan_all
ok "updates: older is not an update" [dict size $::ext_updates] 0

# A version that doesn't follow the rule is never claimed to be newer.
up_publish $U up 2026-07-17
repo_scan_all
ok "updates: incomparable makes no claim" [dict size $::ext_updates] 0
up_publish $U up 1.1.0
repo_scan_all

# --- same-named, different repository: a SWITCH, not an update ----------------------
sources_save [list $U $V]
repo_scan_all
ok "updates: V's 2.0.0 is listed"   [dict get [variant up $::V] version] 2.0.0
ok "updates: still only U's update" [dict get $::ext_updates syntax/up to] 1.1.0
ok "updates: V's variant is not one" [ext_variant_update [variant up $::V]] ""

# ...until the user says these two names mean the same thing.
ext_anysource_set syntax/up 1
ok "anysource: V now counts"        [dict get $::ext_updates syntax/up to] 2.0.0
ok "anysource: the highest wins"    [dict get [dict get $::ext_updates syntax/up variant] source] $::V
ledger_save ; set ::ext_ledger {} ; ledger_load
ok "anysource: survives the ledger" [ext_anysource syntax/up] 1
ext_anysource_set syntax/up 0
ok "anysource: off again"           [dict get $::ext_updates syntax/up to] 1.1.0

# --- the same repository, moved to https (D109) --------------------------------------
# The scheme is how a repository is reached, not which one it is. A user who switches U
# to https keeps U's updates — without needing the any-source switch just turned off,
# which would also admit V.
set Us https://u.example/repo
foreach k [array names ::fix $U/*] {
	set ::fix($Us[string range $k [string length $U] end]) $::fix($k)
}
sources_save [list $Us]
repo_scan_all
ok "https move: U's update survives"  [dict exists $::ext_updates syntax/up] 1
ok "https move: offered from https"   [dict get [dict get $::ext_updates syntax/up variant] source] $Us
ok "https move: same repository"      [list [source_same $U $Us] [source_same HTTPS://u.example/repo $U]] {1 1}
ok "https move: another host is not"  [source_same $U https://v.example/repo] 0
ok "https move: another path is not"  [source_same $U https://u.example/other] 0
sources_save [list $U]
repo_scan_all

# --- Update All: one consent for the batch -------------------------------------------
sources_save [list $U]
repo_scan_all
set ::mb_answers {yes}
ok "update all: install a second"   [ext_install [variant up2 $::U]] 1
up_publish $U up  1.2.0
up_publish $U up2 1.3.0
up_publish $U fresh 9.9.9          ;# never installed: must not be touched
repo_scan_all
ok "update all: two pending"        [dict size $::ext_updates] 2
set before [llength $::mb_log]
set ::mb_answers {yes}
ok "update all: updates both"       [ext_update_all] 2
ok "update all: asked exactly once" [llength $::mb_log] [expr {$before + 1}]
ok "update all: consent lists both" \
	[list [string match "*up *1.0.0 → 1.2.0*" [mb_last]] [string match "*up2*1.0.0 → 1.3.0*" [mb_last]]] {1 1}
ok "update all: consent says which repository" \
	[string match "*repository each was installed from*" [mb_last]] 1
# The batch consent suppresses the per-install dialog, so the one thing that dialog
# would have said about each source has to be on these lines instead (D118).
ok "update all: consent marks each source" \
	[string match "*(unsigned)*" [mb_last]] 1
ok "update all: ledger carries the new versions" \
	[list [dict get $::ext_ledger syntax/up version] [dict get $::ext_ledger syntax/up2 version]] \
	{1.2.0 1.3.0}
ok "update all: nothing left pending" [dict size $::ext_updates] 0
ok "update all: the uninstalled one stayed out" [dict exists $::ext_ledger syntax/fresh] 0
set ::mb_answers {no}
ok "update all: refusing changes nothing" [ext_update_all] 0

# --- a provider's installed version comes from the CORE ------------------------------
# A provider installs core-side (D66), so provider.list — not this GUI's ledger — is the
# truth about what is installed. That is what makes the version right for a provider
# another frontend installed, or one installed onto a shared core (D107).
set ::fix($U/pp-provider/rio-extension.conf) [list 200 \
	"name = pp\nkind = provider\nversion = 1.0.0\nprovider-api = 1\nentry = pp.tcl\nauthor = alice\nfiles = pp.tcl"]
set ::fix($U/pp-provider/pp.tcl) [list 200 "# a provider payload"]
set ::fix($U/index) [list 200 "up-syntax\nup2-syntax\nfresh-syntax\npp-provider\n"]
repo_scan_all
set ::mb_answers {yes}
ok "provider: installs core-side"   [ext_install [variant pp $::U]] 1
# Forget it locally: exactly the state a second frontend on the same core starts in.
dict unset ::ext_ledger provider/pp
set ::ext_core_providers {}
ledger_save
ext_core_providers_refresh
ok "provider: the core still knows it" [dict get $::ext_core_providers pp] \
	[dict create version 1.0.0 source $::U]
ext_installed_compute
ok "provider: installed without a ledger entry" \
	[dict get $::ext_installed provider/pp version] 1.0.0
# The view is DERIVED: what a core says is installed must never be written back into
# this GUI's ledger, or a frontend that talks to two cores in turn persists one core's
# answer as what it believes it installed on the other.
ok "provider: the core's answer stays out of the ledger" \
	[dict exists $::ext_ledger provider/pp] 0
set ::fix($U/pp-provider/rio-extension.conf) [list 200 \
	"name = pp\nkind = provider\nversion = 1.4.0\nprovider-api = 1\nentry = pp.tcl\nauthor = alice\nfiles = pp.tcl"]
repo_scan_all
ok "provider: update detected from the core's version" \
	[list [dict get $::ext_updates provider/pp from] [dict get $::ext_updates provider/pp to]] \
	{1.0.0 1.4.0}
# Installed is not the same as running: a provider is sourced at the next core start
# (D66), so the window says so rather than offering settings for something that cannot
# answer. `pp` is in the core's store and was never loaded, which is exactly that state.
extensions_window
update idletasks
proc pick_row {kind name} {
	set i [rowidx $kind $name]
	.extw.body.list selection clear 0 end
	.extw.body.list selection set $i
	extw_select
}
pick_row provider pp
ok "provider: an installed-but-unloaded one says to restart" \
	[winfo exists .extw.det.restart] 1
ok "provider: and offers no settings button"  [winfo exists .extw.det.settings] 0
# Once the core HAS it — which for a real install means the next start — the same row
# offers the settings it declares. Registering it here is what a restart would do.
namespace eval pploaded {}
proc pploaded::provider {conversation tools system post} { {*}$post done stop }
proc pploaded::opts {} { return {{name flavour value vanilla choices {vanilla mint}}} }
proc pploaded::opt_set {name value} { return }
rio::agent::register_provider pp ::pploaded::provider -label "Peppy" \
	-options [dict create list ::pploaded::opts set ::pploaded::opt_set]
agent_providers_refresh
pick_row provider pp
ok "provider: a loaded one offers its settings" \
	[expr {[winfo exists .extw.det.settings]
		&& [.extw.det.settings cget -text] eq "Peppy settings…"}] 1
ok "provider: and stops telling you to restart" [winfo exists .extw.det.restart] 0
destroy .extw
ok "provider: remove works with no ledger entry" [ext_remove provider pp] 1
ok "provider: the core dropped it" \
	[expr {"pp" in [lmap p [dict get [rio_result provider.list {}] providers] {dict get $p name}]}] 0
ok "provider: no longer installed"  [dict exists $::ext_installed provider/pp] 0
set ::fix($U/index) [list 200 "up-syntax\nup2-syntax\nfresh-syntax\n"]

# --- mode-api: the same contract check, on the mode surface (D123) --------------------
# A mode is sourced into the FRONTEND, and its surface is the one ROADMAP says will
# change — so it declares `mode-api` and is greyed "(needs a newer rio)" when it needs
# more than ::mode_api_max, exactly as a provider is against the core's ceiling. Without
# this the failure is a `source` error on stderr and a mode that is silently absent.
#
# Three cases, and the third is the one that matters most: modes have shipped without
# the key since D38, so ABSENT must mean 1, not "refuse". Anything else would grey vi
# and emacs out of the live repository until every manifest is re-signed.
set ::fix($U/newmode-mode/rio-extension.conf) [list 200 \
	"name = newmode\nkind = mode\nmode-api = 2\nversion = 1.0.0\nauthor = alice\nfiles = newmode.tcl"]
set ::fix($U/newmode-mode/newmode.tcl) [list 200 "# needs a mode surface this rio lacks"]
set ::fix($U/okmode-mode/rio-extension.conf) [list 200 \
	"name = okmode\nkind = mode\nmode-api = 1\nversion = 1.0.0\nauthor = alice\nfiles = okmode.tcl"]
set ::fix($U/okmode-mode/okmode.tcl) [list 200 \
	{rio::modes::register okmode {OK Mode} {apply {tag {}}} {apply {tag {}}}}]
set ::fix($U/oldmode-mode/rio-extension.conf) [list 200 \
	"name = oldmode\nkind = mode\nversion = 1.0.0\nauthor = alice\nfiles = oldmode.tcl"]
set ::fix($U/oldmode-mode/oldmode.tcl) [list 200 \
	{rio::modes::register oldmode {Old Mode} {apply {tag {}}} {apply {tag {}}}}]
set ::fix($U/index) [list 200 \
	"up-syntax\nup2-syntax\nfresh-syntax\nnewmode-mode\nokmode-mode\noldmode-mode\n"]
repo_scan_all

ok "mode-api: a too-new mode is still LISTED" \
	[expr {[variant newmode $::U] ne ""}] 1
ok "mode-api: …and marked too new"      [dict get [variant newmode $::U] too_new] 1
ok "mode-api: …so it cannot install"    [ext_variant_installable [variant newmode $::U]] 0
set before [llength $::mb_log]
ok "mode-api: install refused"          [ext_install [variant newmode $::U]] 0
ok "mode-api: honest reason"            [string match "*needs a newer rio*" [mb_last]] 1
ok "mode-api: no consent asked"         [llength $::mb_log] [expr {$before + 1}]

ok "mode-api: a supported level is not too new" [dict get [variant okmode $::U] too_new] 0
set ::mb_answers {yes}
ok "mode-api: …and installs"            [ext_install [variant okmode $::U]] 1
ok "mode-api: …and registered"          [rio::modes::exists okmode] 1

# Absent means 1 (the D19 fallback). This is the case that must not regress: a mode
# published before the key existed — every mode before D123 — stays installable.
ok "mode-api: absent reads as 1"        [dict get [variant oldmode $::U] api] 1
ok "mode-api: …and is not too new"      [dict get [variant oldmode $::U] too_new] 0
set ::mb_answers {yes}
ok "mode-api: …and still installs"      [ext_install [variant oldmode $::U]] 1

# A kind with NO contract declares nothing and can never be too new — a number on the
# additive theme role table or on syntax would be one nothing ever checks.
ok "mode-api: a syntax carries no contract" [dict exists [variant up $::U] too_new] 0

ok "mode-api: removed cleanly"          [ext_remove mode okmode] 1
ok "mode-api: …and the old one too"     [ext_remove mode oldmode] 1
set ::fix($U/index) [list 200 "up-syntax\nup2-syntax\nfresh-syntax\n"]
repo_scan_all

# --- the start-up check ---------------------------------------------------------------
up_publish $U up 1.5.0
repo_scan_all
set ::ext_check_updates 0
set ::fetches 0
ext_startup_check
ok "startup: off means no network at all" $::fetches 0
ok "startup: off opens nothing"           [winfo exists .extupd] 0
ext_check_arm
ok "startup: off arms no timer"           $::ext_check_after ""

set ::ext_check_updates 1
set ::fetches 0
ext_startup_check
ok "startup: on, it fetched"              [expr {$::fetches > 0}] 1
ok "startup: it reports what it found"    [winfo exists .extupd] 1
ok "startup: the dialog names the change" \
	[string match "*up *1.2.0 → 1.5.0*" [.extupd.list cget -text]] 1
ok "startup: it does not grab"            [grab current] ""
ok "startup: it offers the door onward"   [winfo exists .extupd.btns.ext] 1

# "Don't check again" is the honest escape: it turns the preference off, and says so.
set ::rio_started 1     ;# prefs_save no-ops during boot; here we want the file
.extupd.stop invoke
ok "startup: the checkbutton clears the pref" $::ext_check_updates 0
ok "startup: and it is persisted" \
	[dict get [json::json2dict [slurp_utf8 [prefs_path]]] check_updates] 0
set ::rio_started 0
destroy .extupd
ext_startup_check
ok "startup: cleared means silent again"  [winfo exists .extupd] 0

# The Extensions window says it too: the count in Update All, and the row's own mark.
set ::ext_check_updates 0
extensions_window
ok "window: Update All carries the count" [.extw.hdr.upall cget -text] "Update All (1)"
ok "window: Update All is live"           [.extw.hdr.upall cget -state] normal
ok "window: the row shows the change"     \
	[string match "*\[1.2.0 → 1.5.0\]*" [.extw.body.list get [rowidx syntax up]]] 1
ok "window: an up-to-date row shows its version" \
	[string match "*\[installed 1.3.0\]*" [.extw.body.list get [rowidx syntax up2]]] 1
ok "window: status counts the updates"    \
	[string match "*— 1 update(s)" [.extw.foot.status cget -text]] 1
.extw.body.list selection clear 0 end
.extw.body.list selection set [rowidx syntax up]
extw_select
ok "window: the button says Update"       [.extw.det.v0.in cget -text] Update
ok "window: the cross-source opt-in is there, off" \
	[list [winfo exists .extw.det.anysrc] $::extw_anysource] {1 0}
set ::mb_answers {yes}
.extw.det.v0.in invoke
ok "window: Update installs it"           [dict get $::ext_ledger syntax/up version] 1.5.0
ok "window: nothing pending after"        [.extw.hdr.upall cget -text] "Update All"
ok "window: Update All goes dead at zero" [.extw.hdr.upall cget -state] disabled
destroy .extw

# ===================================================================================
# A certificate that doesn't verify (AGENTS.md D111)
#
# The browser model: the source lists as "certificate not trusted"; Review certificate…
# shows what is wrong and the certificate itself; Go Back is the default and stores
# nothing; Accept stores the fingerprint the dialog SHOWED, in the real core (sandboxed
# certificates.conf); Preferences' Accepted certificates… takes it back. The fetch and the
# inspect are stubbed (no network, D39); accept, list and forget are the real core's.
# ===================================================================================
set T https://t.example/rio
set H http://h.example/rio
set ::fixerr($T/rio-repository.conf) [list untrusted_cert \
	"fetch $T/rio-repository.conf failed: failed to use socket — the server's certificate was refused (self-signed certificate)"]
set ::fixerr($H/rio-repository.conf) [list untrusted_cert \
	"fetch https://h.example/rio/rio-repository.conf failed: … (self-signed certificate)"]
sources_save [list $T $H $DEAD]

set FP1 [join [lrepeat 32 1A] :]
set FP2 [join [lrepeat 32 2B] :]
set ::inspect_calls {}
set ::inspect_answers {}
# Each call takes the next queued answer; the last one repeats. A second call would get a
# DIFFERENT certificate — so an Accept that asked again would store the wrong fingerprint.
proc tls_inspect {url} {
	lappend ::inspect_calls $url
	set a [lindex $::inspect_answers 0]
	if {[llength $::inspect_answers] > 1} { set ::inspect_answers [lrange $::inspect_answers 1 end] }
	return $a
}
proc cert {args} {
	return [dict create ok 1 cert [dict merge [dict create host t.example port 443 \
		subject CN=t.example issuer CN=t.example names t.example \
		not_before {2026-01-01 00:00 UTC} not_after {2027-01-01 00:00 UTC} sha256 $::FP1 \
		problems untrusted reasons {{self-signed certificate}} accepted 0] $args]]
}
proc accepted_now {} {
	set out {}
	foreach e [dict get [rio_call tls.accepted {}] result exceptions] {
		lappend out "[dict get $e host]:[dict get $e port] [dict get $e sha256]"
	}
	return $out
}
proc deadrow {url} {
	for {set i 0} {$i < [llength $::extw_rows]} {incr i} {
		set r [lindex $::extw_rows $i]
		if {[dict exists $r dead] && [dict get $r url] eq $url} { return $i }
	}
	return -1
}
proc select_row {i} {
	.extw.body.list selection clear 0 end
	.extw.body.list selection set $i
	extw_select
}
# Open the review from the selected row, run `script` inside the dialog, and let the
# script close it (a button's invoke).
# Run `script` against the certificate dialog while it is up. The dialog blocks in
# `tkwait window`, so the script has to arrive from the event loop.
#
# It waits for the dialog's FOCUS TO LAND, not for a fixed delay. Measured here, the
# dialog becomes viewable at ~50ms and the focus reaches `.btns.back` between 50 and
# 100ms — so the `after 100` this replaces sat right on the boundary and lost the race
# whenever the machine was busy: about 1 run in 6 under a full-suite run, always on the
# focus check, always reporting `.extcert` instead of `.extcert.btns.back`.
#
# Waiting on `winfo viewable` instead is WORSE, and the reason is worth keeping: the
# window is viewable ~50ms BEFORE the focus transfer, so that condition fires the script
# even earlier and the check then failed every time.
#
# `lastfor == the toplevel` means "not focused yet" *or* "focused nothing", which is the
# ambiguity being waited out. A dialog that genuinely focuses nothing still fails the
# check — it just takes the 3s ceiling to say so.
proc review {script} {
	after 1 [list review_ready $script 0]
	.extw.det.review invoke
}
proc review_ready {script tries} {
	set pending [expr {![winfo exists .extcert] || [focus -lastfor .extcert] eq ".extcert"}]
	if {$pending && $tries < 300} {
		after 10 [list review_ready $script [incr tries]]
		return
	}
	uplevel #0 $script
}

extensions_window
ok "cert: the refused source says so" \
	[string match "*$T — certificate not trusted" [.extw.body.list get [deadrow $T]]] 1
ok "cert: an unreachable one still says unreachable" \
	[string match "*$DEAD — unreachable" [.extw.body.list get [deadrow $DEAD]]] 1
select_row [deadrow $DEAD]
ok "cert: no review for an unreachable source" [winfo exists .extw.det.review] 0
select_row [deadrow $H]
ok "cert: no review for an http source"        [winfo exists .extw.det.review] 0
select_row [deadrow $T]
ok "cert: review offered for the refused one"  [winfo exists .extw.det.review] 1

# Go Back: the default, and nothing is stored.
#
# `focus -lastfor`, not bare `focus`: bare `focus` reports the focus window only while
# the APPLICATION holds the input focus, and a headless run on Windows never does, so it
# answers "" there regardless of what the dialog did. `-lastfor` asks the question the
# check actually means — which widget this toplevel focuses — and still catches a dialog
# that focused nothing, because that answers with the toplevel itself.
set ::inspect_answers [list [cert problems {untrusted expired}]]
review {
	set ::dlg [list [.extcert.btns.back cget -default] [.extcert.btns.accept cget -default] \
		[.extcert.p0 cget -text] [.extcert.p1 cget -text] [.extcert.det get 1.0 end] \
		[bind .extcert <Escape>] [bind .extcert <Return>] [focus -lastfor .extcert]]
	.extcert.btns.back invoke
}
ok "cert: inspected the source's URL"      $::inspect_calls [list $T]
ok "cert: Go Back is the default button"   [lrange $::dlg 0 1] {active disabled}
ok "cert: the untrusted issuer, in words"  [string match "*authority this system doesn't trust*" [lindex $::dlg 2]] 1
ok "cert: the expiry, with its date"       [lindex $::dlg 3] "•  It expired on 2027-01-01 00:00 UTC."
ok "cert: the fingerprint is shown"        [string match "*SHA-256: *$FP1*" [lindex $::dlg 4]] 1
ok "cert: the issuer is shown"             [string match "*Issued by: CN=t.example*" [lindex $::dlg 4]] 1
ok "cert: Go Back stores nothing"          [accepted_now] {}
ok "cert: Escape and Return close it, focus on Go Back" [lrange $::dlg 5 7] {{destroy .extcert} {destroy .extcert} .extcert.btns.back}

# Accept: the SHOWN fingerprint reaches the core, and the list is fetched again.
set ::inspect_calls {}
set ::inspect_answers [list [cert] [cert sha256 $FP2]]
set before $::fetches
review { .extcert.btns.accept invoke }
ok "cert: accept stores the shown fingerprint" [accepted_now] [list "t.example:443 $FP1"]
ok "cert: inspected once, not again at accept" [llength $::inspect_calls] 1
ok "cert: accepting refetches the repositories" [expr {$::fetches > $before}] 1
set f [open [file join $::env(XDG_CONFIG_HOME) rio certificates.conf]] ; set text [read $f] ; close $f
ok "cert: it is certificates.conf, readable" \
	[expr {[string first "\[t.example:443\]\nsha256 = $FP1" $text] >= 0}] 1

# A certificate that changed since it was accepted: said first, and loudly.
select_row [deadrow $T]
set ::inspect_answers [list [cert sha256 $FP2 problems {untrusted changed}]]
review {
	set ::dlg [list [.extcert.p0 cget -text] [.extcert.p0 cget -foreground]]
	.extcert.btns.back invoke
}
ok "cert: a changed certificate is said first" [string match "•  This is NOT the certificate you accepted for t.example:443*" [lindex $::dlg 0]] 1
ok "cert: in the error colour"                 [lindex $::dlg 1] [dict get $::theme_colors error]

# Nothing to accept: the certificate verifies (the refused one was elsewhere), or none came.
select_row [deadrow $T]
set ::inspect_answers [list [cert problems {} reasons {}]]
review {
	set ::dlg [list [winfo exists .extcert.btns.accept] [.extcert.btns.back cget -text] [.extcert.head cget -text]]
	.extcert.btns.back invoke
}
ok "cert: a verifying certificate offers no Accept" [lrange $::dlg 0 1] {0 Close}
ok "cert: and says why, with the fetch's error"     [string match "*verifies, so the refused one belongs to another server*self-signed certificate*" [lindex $::dlg 2]] 1
select_row [deadrow $T]
set ::inspect_answers [list [dict create ok 0 error "connection refused"]]
review {
	set ::dlg [list [winfo exists .extcert.btns.accept] [.extcert.head cget -text]]
	.extcert.btns.back invoke
}
ok "cert: no certificate, no Accept, the reason"    [list [lindex $::dlg 0] [string match "rio couldn't get the certificate: connection refused*" [lindex $::dlg 1]]] {0 1}
ok "cert: still one exception"                      [llength [accepted_now]] 1
destroy .extw

# Preferences ▸ Extensions ▸ Accepted certificates…: listed, and removed through the core.
# The dialog fills itself through the core, so wait for the list before touching it.
proc certs_drive {tries} {
	if {(![winfo exists .certs.body.list] || ![.certs.body.list size]) && $tries > 0} {
		after 50 [list certs_drive [incr tries -1]]
		return
	}
	set ::certs_seen [list [.certs.body.list size] [.certs.body.list get 0]]
	.certs.body.list selection set 0
	certs_remove
	set ::certs_after [.certs.body.list size]
	destroy .certs
}
after 50 [list certs_drive 60]
certs_dialog
ok "certs: the accepted one is listed" [lindex $::certs_seen 0] 1
ok "certs: by host:port and subject"   [string match "t.example:443  —  CN=t.example  —  SHA-256 1A:1A:*" [lindex $::certs_seen 1]] 1
ok "certs: Remove takes it back"       [list $::certs_after [accepted_now]] {0 {}}

# --- signed repositories (AGENTS.md D118) --------------------------------------------
#
# Source S publishes a key and a signature over its files. Everything below runs on
# the stubbed verify seam (above): what is under test here is rio's POLICY — which
# key it trusts, what it refuses, what it installs, and what it says — not the
# cryptography, which is the core's and is tested against real signatures made by
# the real tool in rio-core/tests/sig.test.

set S http://s.example/signed
set KEY1 "ssh-ed25519 AAAAsigningkeyONE"
set KEY2 "ssh-ed25519 AAAAsigningkeyTWO"

proc s_fixtures {{key ""}} {
	global S KEY1
	if {$key eq ""} { set key $KEY1 }
	set marker "name = S repository\ndescription = a signed one\nkey = $key"
	set ::fix($S/rio-repository.conf) [list 200 $marker]
	set ::fix($S/index) [list 200 "sig-mode\n"]
	set ::fix($S/sig-mode/rio-extension.conf) [list 200 \
		"name = sigmode\nkind = mode\nversion = 1.0\nauthor = sam\ndescription = a signed mode\nfiles = sigmode.tcl"]
	set ::fix($S/sig-mode/sigmode.tcl) [list 200 \
		{rio::modes::register sigmode {Sig Mode} {apply {tag {}}} {apply {tag {}}}}]
	fix_sign $S $key {rio-repository.conf index sig-mode/rio-extension.conf sig-mode/sigmode.tcl}
}
# Scan S alone, from a clean trust store unless `keep` is given.
proc s_scan {{keep 0}} {
	global S
	if {!$keep} { set ::repo_keys {} ; repo_keys_save }
	sources_save [list $S]
	repo_scan_all
}
# The same, with S's key already CONFIRMED. Since D119 no scan records a key by
# itself, so this is the state nearly every check below is actually about: without it
# the source is refused as key_unconfirmed and whatever the check meant to test never
# happens. First sight has its own block, just below.
proc s_scan_ok {{key ""}} {
	global S KEY1
	if {$key eq ""} { set key $KEY1 }
	set ::repo_keys {}
	repo_key_trust $S $key
	sources_save [list $S]
	repo_scan_all
}
proc s_dead {} {
	global S
	set d [lsearch -index 0 -inline $::repo_dead $S]
	if {$d eq ""} { return "" }
	return [list [lindex $d 2] [lindex $d 1]]
}
proc s_code {} { return [lindex [s_dead] 0] }
proc keys_file {} {
	if {![file exists [repo_keys_path]]} { return "" }
	set f [open [repo_keys_path] r] ; set t [read $f] ; close $f
	return $t
}
set TODAY [clock format [clock seconds] -format %Y-%m-%d]

# --- the sums file --------------------------------------------------------------
ok "sums: the shape sha256sum prints" \
	[repo_sums_parse "[string repeat a 64]  index\n[string repeat b 64]  vi/vi.tcl\n"] \
	[list index [string repeat a 64] vi/vi.tcl [string repeat b 64]]
ok "sums: binary-mode star and a leading ./ (BSD sha256 -r, a publisher's find)" \
	[repo_sums_parse "[string repeat c 64] *./vi/vi.tcl\n"] \
	[list vi/vi.tcl [string repeat c 64]]
ok "sums: a line that names no file is skipped, not fatal" \
	[dict size [repo_sums_parse "not a hash line\n\n[string repeat d 64]  index\n"]] 1
ok "sums: hashes fold to lower case" \
	[dict get [repo_sums_parse "[string repeat A 64]  index"] index] [string repeat a 64]

# --- first sight: a key is trusted when the user says so (D119) ---------------------
# ssh prints the fingerprint and waits for `yes`; rio refuses the source and offers the
# same fingerprint on its row. The scan itself records NOTHING — recording it would
# hand an attacker on the path during the very first scan a permanent trust decision
# the user never took, and rio would then defend that key faithfully forever.
s_fixtures
s_scan
ok "first sight: the source is refused"       [s_code] key_unconfirmed
ok "first sight: nothing from it is listed"   [llength $::repo_variants] 0
ok "first sight: no key is trusted"           [repo_key_of $S] ""
ok "first sight: and nothing is written down" [dict exists $::repo_keys [source_key $S]] 0
ok "first sight: not even a file"             [string match "*s.example/signed*" [keys_file]] 0
ok "first sight: the row carries the offered key" \
	[lindex [lsearch -index 0 -inline $::repo_dead $S] 3] $KEY1
ok "first sight: in the words the row has"    [dead_phrase [s_code]] "signing key not confirmed"
ok "first sight: and the sentence says what is being asked" \
	[string match "*never been told to trust*confirm*fingerprint*" [lindex [s_dead] 1]] 1
# The refusal is raised only after the signature verified AND the marker was checked
# against the sums it pointed at, so rio never offers a key that signs nothing.
ok "first sight: the signature was checked first, on this source's sums" \
	[lrange [lindex $::sig_calls end] 1 2] [list $KEY1 $S]

# The explicit step, as the dialog performs it.
repo_key_trust $S $KEY1
s_scan 1
ok "confirmed: the source scanned"      [s_code] {}
ok "confirmed: its extension is listed" [llength $::repo_variants] 1
ok "confirmed: marked signed"           [dict get [lindex $::repo_variants 0] sig] signed
ok "confirmed: and says who signed it"  [dict get [lindex $::repo_variants 0] signer] [sig_fingerprint $KEY1]
ok "confirmed: written down"            [dict get $::repo_keys [source_key $S] key] $KEY1
ok "confirmed: with the date"           [dict get $::repo_keys [source_key $S] trusted] $TODAY
ok "confirmed: the file is conf, sectioned by source" \
	[string match "*\[s.example/signed\]*key = $KEY1*" [keys_file]] 1

# The trust store survives a restart, and is re-read per scan because it is meant to
# be editable by hand.
set ::repo_keys {}
repo_keys_load
ok "keys: reload from disk"            [repo_key_of $S] $KEY1

# --- the seed ---------------------------------------------------------------------
# rio's own repository is trusted out of the box, so a first scan of it is not a
# question the user has no way to answer.
ok "seed: the default repo's key is pre-trusted" \
	[repo_key_of $::default_repo] $::default_repo_key
ok "seed: and the https route to it is the same trust (D109)" \
	[repo_key_of [string map {http:// https://} $::default_repo]] $::default_repo_key
ok "seed: an unrelated source is not" [repo_key_of http://other.example/x] ""

# The seed is a fallback, not an entry, so withdrawing it is the one act that WRITES.
# A section with no `key` at all is not an empty entry: it says rio trusts no key for
# this source, and it beats the seed (D119).
set ::repo_keys {}
dict set ::repo_keys [source_key $::default_repo] \
	[dict create key "" trusted "" forgotten $TODAY]
repo_keys_save
ok "seed: a keyless section withdraws it" [repo_key_of $::default_repo] ""
ok "seed: over https too (D109)" \
	[repo_key_of [string map {http:// https://} $::default_repo]] ""
ok "seed: written as a date, with no key" \
	[list [string match "*forgotten = $TODAY*" [keys_file]] [string match "*key = *" [keys_file]]] {1 0}
set ::repo_keys {} ; repo_keys_load
ok "seed: and the withdrawal survives a restart" [repo_key_of $::default_repo] ""
repo_key_trust $::default_repo $::default_repo_key
ok "seed: confirming a key later overwrites it" \
	[repo_key_of $::default_repo] $::default_repo_key
ok "seed: and the forgotten line is gone"        [string match "*forgotten*" [keys_file]] 0
set ::repo_keys {} ; repo_keys_save

# --- a tampered payload -------------------------------------------------------------
# The signature still verifies (SHA256SUMS is untouched); it is the FILE that changed.
# Nothing may be written, and the message must name the file.
s_fixtures
s_scan_ok
set ::mb_log {}
set v [variant sigmode $S]
ok "tamper: the variant is installable" [expr {$v ne ""}] 1
set ::fix($S/sig-mode/sigmode.tcl) [list 200 "# rewritten in flight\nrio::modes::register sigmode {Sig Mode} {apply {tag {}}} {apply {tag {}}}"]
set ::mb_answers {yes}
ok "tamper: install refused"            [ext_install $v] 0
ok "tamper: and says which file"        [string match "*sig-mode/sigmode.tcl is not the file*" [mb_last]] 1
ok "tamper: nothing was installed"      [dict exists $::ext_ledger mode/sigmode] 0
ok "tamper: and nothing written to disk" [file exists [file join [modes_user_dir] sigmode.tcl]] 0

# --- a tampered manifest, found at scan ---------------------------------------------
s_fixtures
set ::fix($S/sig-mode/rio-extension.conf) [list 200 \
	"name = sigmode\nkind = mode\nversion = 9.9\nauthor = sam\nfiles = sigmode.tcl"]
s_scan_ok
ok "tamper: a manifest that isn't the signed one kills the source" [s_code] hash_mismatch
ok "tamper: no variants survive it"     [llength $::repo_variants] 0
ok "tamper: the row names the file"     [string match "*sig-mode/rio-extension.conf is not the file*" [lindex [s_dead] 1]] 1

# --- a file the sums don't mention ---------------------------------------------------
# A publisher's SHA256SUMS covers everything served, so an unlisted file is not an
# omission — it is a file that arrived from somewhere else.
s_fixtures
set ::fix($S/index) [list 200 "sig-mode\nextra-mode\n"]
set ::fix($S/extra-mode/rio-extension.conf) [list 200 \
	"name = extra\nkind = mode\nversion = 1.0\nauthor = nobody\nfiles = extra.tcl"]
fix_sign $S $KEY1 {rio-repository.conf index sig-mode/rio-extension.conf sig-mode/sigmode.tcl}
s_scan_ok
ok "unlisted: an unsigned extra file kills the source" [s_code] hash_mismatch

# --- the marker is covered by the sums it pointed at --------------------------------
# The marker carried the key, so it has to be one of the files the signature vouches
# for — and that is checked BEFORE the user is ever asked about the key (D119), or rio
# would put a fingerprint in front of them for a key that signs nothing here. So these
# scans, with nothing trusted, must die of the marker rather than of the question.
s_fixtures
fix_sign $S $KEY1 {index sig-mode/rio-extension.conf sig-mode/sigmode.tcl}
s_scan
ok "marker: a marker the sums don't cover is refused" [s_code] hash_mismatch
ok "marker: not offered for confirmation"             [expr {[s_code] eq "key_unconfirmed"}] 0
ok "marker: and no key was trusted on the way out"    [repo_key_of $S] ""
s_fixtures
set ::fix($S/rio-repository.conf) [list 200 \
	"name = S repository\ndescription = edited after signing\nkey = $KEY1"]
s_scan
ok "marker: a marker edited after signing is refused" [s_code] hash_mismatch
ok "marker: still nothing trusted"                    [repo_key_of $S] ""

# --- a changed key --------------------------------------------------------------------
s_fixtures
s_scan_ok
ok "rotation: trusted the first key"   [repo_key_of $S] $KEY1
s_fixtures $KEY2
s_scan 1
ok "rotation: the new key is refused"  [s_code] key_changed
ok "rotation: nothing from it is listed" [llength $::repo_variants] 0
ok "rotation: the old key is still the trusted one" [repo_key_of $S] $KEY1
ok "rotation: the row offers the new key to the dialog" \
	[lindex [lsearch -index 0 -inline $::repo_dead $S] 3] $KEY2
# The explicit step, as the dialog performs it.
repo_key_trust $S $KEY2
s_scan 1
ok "rotation: after trusting it, the source is back" [s_code] {}
ok "rotation: signed by the new key"   [dict get [lindex $::repo_variants 0] signer] [sig_fingerprint $KEY2]

# --- the signature going away ----------------------------------------------------------
s_fixtures
s_scan_ok
set ::fix($S/rio-repository.conf) [list 200 "name = S repository\ndescription = a signed one"]
s_scan 1
ok "downgrade: dropping the key is refused" [s_code] sig_dropped
s_fixtures
unset ::fix($S/SHA256SUMS.sig)
s_scan 1
ok "downgrade: losing the signature file is refused" [s_code] sig_missing
s_fixtures
set ::fix($S/SHA256SUMS.sig) [list 200 [sig_sign $KEY2]]
s_scan 1
ok "downgrade: a signature by another key is refused" [s_code] sig_bad
ok "downgrade: and says so in the row"  [string match "*doesn't verify*" [lindex [s_dead] 1]] 1

# --- no ssh-keygen on the core's host ----------------------------------------------------
set ::sig_available 0
s_fixtures
s_scan 1                                  ;# S's key is still trusted from above
ok "no tool: a trusted source is refused" [s_code] sig_no_tool
ok "no tool: the message names the fix"   [string match "*openssh 8.0 or newer*Preferences*" [lindex [s_dead] 1]] 1
set ::repo_allow_unverified 1
s_scan 1
ok "no tool: the switch lets it through"  [s_code] {}
ok "no tool: marked unverified, never signed" [dict get [lindex $::repo_variants 0] sig] unverified
# The switch buys exactly one thing. A signature that FAILS is still a refusal.
set ::sig_available 1
set ::fix($S/SHA256SUMS.sig) [list 200 [sig_sign $KEY2]]
s_scan 1
ok "no tool: the switch does not excuse a bad signature" [s_code] sig_bad
set ::repo_allow_unverified 0
# A source nobody has trusted yet loses nothing by being unsigned, so it stays listed.
s_fixtures
set ::sig_available 0
s_scan
ok "no tool: an untrusted source just lists as unsigned" \
	[list [s_code] [dict get [lindex $::repo_variants 0] sig]] {{} unsigned}
ok "no tool: and trusts nothing"        [repo_key_of $S] ""
set ::sig_available 1

# --- a core too old to hash what it fetches ------------------------------------------------
# D30 lets this GUI attach to any core, including one from before D118, which answers
# repo.fetch without a hash however politely it is asked. Nothing can be checked then
# either — and it must be found as that, not as a Tcl error at the first comparison.
rename repo_fetch _hashless_real
proc repo_fetch {url {hash 0}} {
	set r [_hashless_real $url $hash]
	if {[dict exists $r sha256]} { dict unset r sha256 }
	return $r
}
s_fixtures
s_scan                                    ;# untrusted: nothing was going to be checked
ok "old core: an untrusted source still lists" \
	[list [s_code] [dict get [lindex $::repo_variants 0] sig]] {{} unsigned}
repo_key_trust $S $KEY1
s_scan 1
ok "old core: a trusted source is refused"  [s_code] sig_no_tool
ok "old core: and says what is too old"     [string match "*older than rio's repository signing*" [lindex [s_dead] 1]] 1
set ::repo_allow_unverified 1
s_scan 1
ok "old core: the switch lets it through as unverified" \
	[list [s_code] [dict get [lindex $::repo_variants 0] sig]] {{} unverified}
set ::repo_allow_unverified 0
rename repo_fetch {} ; rename _hashless_real repo_fetch

# --- an unsigned repository is unchanged -------------------------------------------------
sources_save [list $A]
set ::repo_keys {} ; repo_keys_save
repo_scan_all
ok "unsigned: still scans"              [llength $::repo_dead] 0
ok "unsigned: marked unsigned"          [dict get [variant zz $A] sig] unsigned
ok "unsigned: and nothing is trusted"   [repo_key_of $A] ""
ok "unsigned: no signature was asked about" \
	[expr {[lsearch -index 2 $::sig_calls $A] < 0}] 1

# --- what the user is told ----------------------------------------------------------------
ok "marks: the three words"             [list [sig_mark signed] [sig_mark unsigned] [sig_mark unverified]] \
	{signed unsigned unverified}
ok "consent: an unsigned source says nothing vouches for it" \
	[string match "NOT SIGNED*" [ext_consent_sig_line $A]] 1
s_fixtures
s_scan_ok
ok "consent: a signed one names the key" \
	[string match "Signed by [sig_fingerprint $KEY1],*" [ext_consent_sig_line $S]] 1
ok "dead rows: a phrase per refusal" \
	[list [dead_phrase key_unconfirmed] [dead_phrase key_changed] [dead_phrase sig_bad] \
		[dead_phrase sig_no_tool] [dead_phrase untrusted_cert] [dead_phrase io_error]] \
	[list "signing key not confirmed" "signing key changed" "signature doesn't verify" \
		"can't check the signature" "certificate not trusted" "unreachable"]

# --- the ledger records who vouched ---------------------------------------------------------
s_fixtures
s_scan_ok
set ::mb_answers {yes}
ok "ledger: the signed install goes through" [ext_install [variant sigmode $S]] 1
ok "ledger: signed_by is the signer"    [dict get $::ext_ledger mode/sigmode signed_by] [sig_fingerprint $KEY1]
ledger_save ; ledger_load
ok "ledger: it survives a save/load"    [dict get $::ext_ledger mode/sigmode signed_by] \
	[sig_fingerprint $KEY1]
ext_remove mode sigmode
# …and an unsigned one still writes the pre-D118 shape, with no empty field in it.
sources_save [list $A]
repo_scan_all
set ::mb_answers {yes}
ext_install [variant night $A]
ok "ledger: an unsigned install records no signer" \
	[dict exists $::ext_ledger theme/night signed_by] 0
ext_remove theme night

# --- Preferences ▸ Extensions ▸ Repository signing keys… -------------------------------------
# The list of what rio recorded, and Forget. The dialog blocks in tkwait, so the
# script that drives it runs from the event loop, as the certificates dialog's does.
proc keys_drive {script} {
	after 50 [list keys_ready $script 0]
	repo_keys_dialog
}
proc keys_ready {script tries} {
	if {![winfo exists .repokeys.body.list] && $tries < 300} {
		after 10 [list keys_ready $script [incr tries]]
		return
	}
	uplevel #0 $script
	if {[winfo exists .repokeys]} { destroy .repokeys }
}

s_fixtures
s_scan_ok                                 ;# S's key confirmed; sources.list is S alone
keys_drive { set ::keys_seen [list [.repokeys.body.list size] [.repokeys.body.list get 0]] }
# One row, and only one: rio's own repository is not in this sources list, and a key
# for a source the user removed speaks for nothing.
ok "keys: the trusted key is listed, alone" [lindex $::keys_seen 0] 1
ok "keys: scheme-less, with fingerprint and date" [lindex $::keys_seen 1] \
	"s.example/signed  —  [sig_fingerprint $KEY1]  (trusted $TODAY)"

# The seed is trusted without ever being written down, so it has to be listed from the
# seed itself — otherwise a fresh install shows an empty window while rio does trust a key.
sources_save [list $S $::default_repo]
keys_drive {
	set ::keys_seen [list [.repokeys.body.list get 0] [.repokeys.body.list get 1]]
	set ::keys_bind [bind .repokeys.body.list <<ListboxSelect>>]
	.repokeys.body.list selection set 1
	# The selection carries the note. `event generate` can't deliver a virtual event
	# to an unmapped window, so the binding is checked separately (below) and the
	# handler called the way that binding would.
	repo_keys_sel
	set ::keys_note [.repokeys.status cget -text]
	repo_keys_forget
	set ::keys_after [list [.repokeys.body.list size] \
		[dict exists $::repo_keys [source_key $::default_repo]] \
		[.repokeys.status cget -text] [.repokeys.body.list get 1]]
}
ok "keys: rio's own repository is listed as built in" \
	[lindex $::keys_seen 1] "rio.skylm.org/extensions  —  [sig_fingerprint $::default_repo_key]  (built in)"
ok "keys: selecting it says it is the one key nobody was asked about" \
	[string match "rio ships with this key*Forget withdraws it*" $::keys_note] 1
ok "keys: and the selection really runs that" [lindex $::keys_bind 0] repo_keys_sel
# Forget on the built-in row WRITES rather than deletes: the seed is a fallback, so
# the only way to take it back is to record that nothing is trusted here (D119).
ok "keys: Forget withdraws it, and records that" [lrange $::keys_after 0 1] {2 1}
ok "keys: and says the next scan will ask" \
	[string match "*withdrawn its built-in key*asks you to confirm*" [lindex $::keys_after 2]] 1
ok "keys: the row stays, marked withdrawn" \
	[lindex $::keys_after 3] "rio.skylm.org/extensions  —  [sig_fingerprint $::default_repo_key]  (built in, withdrawn)"
ok "keys: the seed no longer speaks for that repository" [repo_key_of $::default_repo] ""
ok "keys: the conf file says so, with no key" \
	[list [expr {[string first "\[rio.skylm.org/extensions\]\nforgotten = $TODAY" [keys_file]] >= 0}] \
		[string match "*rio.skylm.org*key = *" [keys_file]]] {1 0}
# Selecting the withdrawn row explains the state it is in, and Forget on it is a
# no-op — it must not claim to have withdrawn anything a second time. Driven from a
# reloaded store, because a withdrawal that only held in memory would put the seed
# back on the next start and the user would never be told.
set ::repo_keys {} ; repo_keys_load
ok "keys: and the withdrawal is still in force after a restart" \
	[repo_key_of $::default_repo] ""
keys_drive {
	.repokeys.body.list selection set 1
	repo_keys_sel
	set ::keys_wnote [.repokeys.status cget -text]
	repo_keys_forget
	set ::keys_wafter [list [.repokeys.body.list size] [.repokeys.status cget -text]]
}
ok "keys: the withdrawn row says what it means" \
	[string match "You have withdrawn*asks about that repository's key like any other*" $::keys_wnote] 1
ok "keys: Forget on it changes nothing and says nothing new" \
	[list [lindex $::keys_wafter 0] [string match "You have withdrawn*" [lindex $::keys_wafter 1]]] {2 1}
# Put the seed back, the way confirming in the dialog would.
repo_key_trust $::default_repo $::default_repo_key
set ::repo_keys [dict remove $::repo_keys [source_key $::default_repo]]
repo_keys_save

keys_drive {
	.repokeys.body.list selection set 0
	repo_keys_forget
	set ::keys_gone [list [.repokeys.body.list size] [dict exists $::repo_keys [source_key $S]] \
		[.repokeys.status cget -text]]
}
ok "keys: Forget drops the stored key"  [lrange $::keys_gone 0 1] {1 0}
ok "keys: and says the next scan will ask" \
	[string match "*forgotten the key for s.example/signed*asks you to confirm*" [lindex $::keys_gone 2]] 1
ok "keys: the conf file no longer holds it" [string match "*s.example/signed*" [keys_file]] 0
# An ordinary Forget needs no tombstone: with no silent trust anywhere, deleting the
# section IS the whole act, and the next scan refuses the source until it is answered.
s_scan 1
ok "keys: the next scan asks again"     [s_code] key_unconfirmed
ok "keys: and still trusts nothing"     [repo_key_of $S] ""
repo_key_trust $S $KEY1                   ;# confirmed again, as the dialog does
ok "keys: confirming records it, dated today" \
	[dict get $::repo_keys [source_key $S] trusted] $TODAY

# A core with no ssh-keygen has no fingerprint to give, and a row still has to say
# WHICH key it is — that is the only reason the row exists.
set ::sig_available 0
keys_drive { set ::keys_nofp [.repokeys.body.list get 0] }
set ::sig_available 1
ok "keys: no ssh-keygen, so the key itself names the row" \
	[string match "s.example/signed  —  ssh-ed25519 AAAAsigningkeyON…*" $::keys_nofp] 1

set ::repo_keys {} ; repo_keys_save
sources_save [list $S]
keys_drive { set ::keys_empty [list [.repokeys.body.list size] [.repokeys.status cget -text]] }
ok "keys: nothing confirmed, nothing listed" [lindex $::keys_empty 0] 0
ok "keys: and the window says so"          [string match "You haven't confirmed a signing key*" [lindex $::keys_empty 1]] 1

# --- confirming a key from the Extensions window (D119) --------------------------------
# The refused row's door, and what is behind it. Same shape as the certificate review
# above: the row offers a button, the dialog shows the fingerprint, Go Back leaves the
# source refused, and what gets trusted is the key the dialog SHOWED.
proc keyreview {script} {
	after 1 [list keyreview_ready $script 0]
	.extw.det.keyreview invoke
}
proc keyreview_ready {script tries} {
	set pending [expr {![winfo exists .extkey] || [focus -lastfor .extkey] eq ".extkey"}]
	if {$pending && $tries < 300} {
		after 10 [list keyreview_ready $script [incr tries]]
		return
	}
	uplevel #0 $script
}
s_fixtures
s_scan                                    ;# nothing confirmed: S is refused
extensions_window
ok "confirm: the row says the key isn't confirmed" \
	[string match "*$S — signing key not confirmed" [.extw.body.list get [deadrow $S]]] 1
select_row [deadrow $S]
ok "confirm: and offers the review"     [winfo exists .extw.det.keyreview] 1
keyreview {
	set ::kdlg [list [wm title .extkey] [.extkey.head cget -text] [.extkey.det get 1.0 end] \
		[.extkey.btns.back cget -default] [.extkey.btns.trust cget -text] \
		[.extkey.hint cget -text] [focus -lastfor .extkey]]
	.extkey.btns.back invoke
}
ok "confirm: the title asks rather than warns"  [lindex $::kdlg 0] "Confirm signing key"
ok "confirm: the head says this is the first key rio has seen" \
	[string match "*first time rio has seen a key for it*" [lindex $::kdlg 1]] 1
ok "confirm: one fingerprint, and no Trusted line to compare against" \
	[list [string match "*Offered*[sig_fingerprint $KEY1]*" [lindex $::kdlg 2]] \
		[string match "*Trusted*" [lindex $::kdlg 2]]] {1 0}
ok "confirm: Go Back is still the default, and has the focus" \
	[list [lindex $::kdlg 3] [lindex $::kdlg 6]] {active .extkey.btns.back}
ok "confirm: the other button says what it does" [lindex $::kdlg 4] "Trust This Key"
ok "confirm: the hint sends the user off this connection" \
	[string match "*away from this connection*publisher's own page*" [lindex $::kdlg 5]] 1
ok "confirm: Go Back trusts nothing"    [repo_key_of $S] ""
ok "confirm: and the source is still refused" [s_code] key_unconfirmed

# Trust: the key the dialog showed is recorded, even if the repository has swapped its
# marker in the meantime — the same rule extw_cert_review follows for a fingerprint.
select_row [deadrow $S]
keyreview {
	s_fixtures $KEY2                      ;# the server changes its mind mid-click
	.extkey.btns.trust invoke
}
ok "confirm: the key the dialog showed is the one trusted" [repo_key_of $S] $KEY1
ok "confirm: written with today's date" [dict get $::repo_keys [source_key $S] trusted] $TODAY
destroy .extw
s_fixtures
s_scan 1
ok "confirm: and the source scans"      [s_code] {}
ok "confirm: with its extension listed" [llength $::repo_variants] 1

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

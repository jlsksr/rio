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
proc repo_fetch {url} {
	if {[info exists ::fix($url)]} {
		lassign $::fix($url) status text
		return [dict create ok 1 status $status text $text]
	}
	return [dict create ok 0 error "connection refused (stub)"]
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
set found 0
for {set i 0} {$i <= [.m.view.theme index end]} {incr i} {
	if {[.m.view.theme entrycget $i -label] eq "Night"} { set found 1 }
}
ok "theme: menu radio filled" $found 1
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
	.extsrc.add.url insert end https://nope.example/tls
	extw_source_add
	set ::src_mid [sources_load]
	.extsrc.body.list selection set 0
	extw_source_remove
	set ::src_after [sources_load]
	destroy .extsrc
}
extw_sources_dialog
ok "sources dialog: http added"     [expr {"http://e.example/more" in $::src_mid}] 1
ok "sources dialog: https refused"  [string match "*https is not supported yet*" [mb_last]] 1
ok "sources dialog: only http kept" [llength $::src_mid] 1
ok "sources dialog: remove removes" $::src_after {}
destroy .extw

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

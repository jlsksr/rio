#!/usr/bin/env wish
#
# Headless docs test for the user manual (AGENTS.md D91): docs/ is one Markdown topic
# per file, and the filename IS the topic id — so a page nobody links to, a contents
# entry pointing at nothing, or a dead relative link are all bugs a help viewer would
# hit later. This is also the check that would have caught the stale INSTALL shortcut
# table that motivated D91: it holds keyboard.md against ::keymap_default, the one
# source of truth for the chords (D23).
#
# Needs a DISPLAY (Tk) only because it sources rio-gui.tcl for ::keymap_default; shows
# no window and opens no files.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/docs.tcl

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

set ::docs [file normalize [file join [file dirname [info script]] .. .. docs]]

proc slurp {path} {
	set f [open $path r] ; fconfigure $f -encoding utf-8
	set t [read $f] ; close $f
	return $t
}
# Every relative Markdown link target in a page, with any #anchor stripped. Absolute
# URLs (http:, mailto:) are somebody else's problem; ../ links leave docs/ and are
# checked against the repo root.
proc md_links {text} {
	set out {}
	foreach {_ target} [regexp -all -inline {\]\(([^)]+)\)} $text] {
		if {[regexp {^[a-z][a-z0-9+.-]*:} $target]} continue
		lappend out [lindex [split $target #] 0]
	}
	return $out
}

# --- the folder itself --------------------------------------------------------

set pages {}
foreach p [lsort [glob -nocomplain -directory $::docs *.md]] {
	lappend pages [file tail $p]
}
ok "docs/ has pages"          [expr {[llength $pages] > 1}] 1
ok "docs/index.md exists"     [file exists [file join $::docs index.md]] 1

set index [slurp [file join $::docs index.md]]

# --- 1. contents and folder agree (no orphans, no dead entries) ---------------

# Everything index.md links to, that lives in docs/ itself.
set listed {}
foreach t [md_links $index] {
	if {[string match */* $t]} continue ;# ../README.md and friends: checked below
	lappend listed $t
}
set listed [lsort -unique $listed]

set orphans {}   ;# a page no contents entry reaches — invisible in a help viewer
foreach p $pages {
	if {$p eq "index.md"} continue
	if {[lsearch -exact $listed $p] < 0} { lappend orphans $p }
}
ok "every page is listed in index.md" $orphans {}

set dead {}      ;# a contents entry pointing at a page that isn't there
foreach t $listed {
	if {![file exists [file join $::docs $t]]} { lappend dead $t }
}
ok "every index.md entry exists" $dead {}

# --- 2. every relative link in every page resolves ---------------------------

set broken {}
foreach p $pages {
	foreach t [md_links [slurp [file join $::docs $p]]] {
		if {$t eq ""} continue ;# a bare #anchor within the same page
		if {![file exists [file join $::docs $t]]} { lappend broken "$p -> $t" }
	}
}
ok "every relative link resolves" $broken {}

# --- 3. keyboard.md covers every command in the keymap -----------------------
#
# The stale-table check. ::keymap_default is the single source of truth for the
# chords (D23); a command added there without a line in the manual is exactly the
# drift that lost seven commands from INSTALL's table before D91.

set kb [slurp [file join $::docs keyboard.md]]
set missing {}
foreach {cmd spec} $::keymap_default {
	if {![string match "*`$cmd`*" $kb]} { lappend missing $cmd }
}
ok "keyboard.md documents every command" $missing {}

# ...and doesn't invent any. A row for a command that no longer exists is the same
# drift in the other direction.
set invented {}
foreach {_ cmd} [regexp -all -inline -line {^\| `([a-z-]+)` \|} $kb] {
	if {![dict exists $::keymap_default $cmd]} { lappend invented $cmd }
}
ok "keyboard.md invents no command" $invented {}

# --- 4. preferences.md's key table matches what prefs_save actually writes ----
#
# Second row of AGENTS.md §7's derived-facts register. The source of truth is the
# behaviour, not the source text: write a real prefs.json into the sandbox and read
# its keys back. That is why the register's other unguarded rows matter — this table
# had already lost seven keys (font, tab layout, the last project) by the time it was
# written down.

set prefs [slurp [file join $::docs preferences.md]]
set ::rio_started 1 ;# prefs_save no-ops during boot; we want the file
prefs_save
set ::rio_started 0

set written {}
if {[file exists [prefs_path]]} {
	set written [lsort [dict keys [json::json2dict [slurp [prefs_path]]]]]
}
ok "prefs_save wrote a file" [expr {[llength $written] > 1}] 1

# Rows of the key table: `| \`key\` |`. The path tables below can't collide — every
# path there carries a `.`, a `/` or a `*`.
set documented {}
foreach {_ k} [regexp -all -inline -line {^\s*\| `([a-z_]+)` \|} $prefs] { lappend documented $k }
set documented [lsort -unique $documented]

set undocumented {}
foreach k $written {
	if {[lsearch -exact $documented $k] < 0} { lappend undocumented $k }
}
ok "preferences.md documents every prefs.json key" $undocumented {}

set phantom {}
foreach k $documented {
	if {[lsearch -exact $written $k] < 0} { lappend phantom $k }
}
ok "preferences.md invents no prefs.json key" $phantom {}

# --- 5. "Where everything lives" matches the paths the code builds ------------
#
# Third register row. Every config/data location comes from exactly one proc; this
# holds the two tables against them in both directions. It is the check that would
# have caught the agent files (added to the code, never to the table) and the
# provider store, both of which were missing when docs/ was first written.

# proc to call -> which XDG root its result hangs under
set producers {
	{prefs_path}                        config
	{keys_path}                         config
	{sources_path}                      config
	{hl_user_dir}                       config
	{modes_user_dir}                    config
	{lindex [rio::theme::searchdirs] 0} config
	{rio::agent::prompt::_userdir}      config
	{rio::agent::allow::_dir}           config
	{ledger_path}                       data
	{rio::secret::_dir}                 data
	{rio::workspace::_dir}              data
	{rio::provider::_dir}               data
}

# The first path segment of a table cell — `agent/providers/<name>.md` and
# `secrets/*.secret` both reduce to what the code actually names.
proc first_seg {p} { return [lindex [split [string trimright $p /] /] 0] }

# The two XDG tables, sliced apart so a config path can't satisfy a data row.
proc doc_segs {text from to} {
	set body [string range $text [string first $from $text] \
		[expr {[string first $to $text] - 1}]]
	set out {}
	foreach {_ cell} [regexp -all -inline -line {^\| `([^`]+)` \|} $body] {
		lappend out [first_seg $cell]
	}
	return [lsort -unique $out]
}
set doc(config) [doc_segs $prefs "**Config —" "**Data —"]
set doc(data)   [doc_segs $prefs "**Data —"   "**Project-local"]

set missing {}
set produced(config) {} ; set produced(data) {}
foreach {call root} $producers {
	set seg [file tail [uplevel #0 $call]]
	lappend produced($root) $seg
	if {[lsearch -exact $doc($root) $seg] < 0} { lappend missing "$root/$seg ($call)" }
}
ok "every config & data path is documented" $missing {}

set orphaned {}
foreach root {config data} {
	foreach seg $doc($root) {
		if {[lsearch -exact $produced($root) $seg] < 0} { lappend orphaned "$root/$seg" }
	}
}
ok "no documented path the code never builds" $orphaned {}

puts [expr {$::fails ? "FAILED ($::fails)" : "ALL PASS"}]
exit [expr {$::fails ? 1 : 0}]

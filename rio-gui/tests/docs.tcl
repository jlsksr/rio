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

# --- 6. every "Menu ▸ Item" path the docs quote is a real menu entry -----------
#
# Fourth register row, which was the honest backlog until now. A menu path is the most
# quotable fact rio has and the easiest to leave behind: D64 regrouped View into
# submenus, D74 retired the Tabs cascade and D92 the Theme one, and each move silently
# invalidated every page that had written the old path down. (This check was written
# after finding `View ▸ Font…` in two documents, three decisions after the font item
# moved under `Font & Zoom`.)
#
# Behaviour, not source text: the menubar is built by sourcing rio-gui.tcl above, so
# this walks the real Tk widgets with `entrycget`.
#
# ONE direction only. Unlike the tables above, a menu has no counterpart list to be
# complete against — "every entry is documented somewhere" would demand a page mention
# for every checkbutton in View, which is not a thing any manual should promise.

# Every menu the docs could name, by the label it is known by: the menubar's own
# cascades and every cascade beneath them ("View", "Font & Zoom", "Dock Side"). A `▸`
# whose left side names none of these is not a rio menubar path at all, which is what
# keeps window paths (`Preferences ▸ Agent`), context menus (`Move to ▸ Left`) and the
# tab-strip arrows (`◂ ▸`) out of the check without naming them.
array set ::menus {}
proc menus_collect {menu} {
	for {set i 0} {$i <= [$menu index end]} {incr i} {
		if {[catch {$menu entrycget $i -label} l] || $l eq ""} continue
		if {[catch {$menu entrycget $i -menu} sub] || $sub eq ""} continue
		if {[info exists ::menus($l)]} continue ;# first wins; no two cascades share a label
		set ::menus($l) $sub
		menus_collect $sub
	}
}
menus_collect .m

# Cascades filled at runtime from the core (providers, installed modes): their entries
# are installed data, not facts of the code, so a path is checked down to the cascade
# and whatever follows is taken on trust.
set ::datamenus {.m.settings.provider .m.settings.editmode}

# Paths that are emphatically not rio's menus — Windows' own Settings app, quoted in
# WINDOWS.md. Listed one by one rather than pattern-skipped, so the next such path has to
# be admitted deliberately instead of quietly slipping through.
set ::notrio {
	{Settings ▸ System}
}

# Words of a label or a captured segment, each stripped of the sentence punctuation a
# doc leaves clinging to it ("Theme…:", "Extensions….", "…edits*) — and"). Both sides
# are stripped the same way, so this forgives the sentence, never the label.
proc menu_words {s} {
	set out {}
	foreach w [split $s] {
		set w [string trimleft $w "(\"“"]
		set w [string trimright $w ".,;:)\"”"]
		if {$w ne ""} { lappend out $w }
	}
	return $out
}

# Does $menu carry an entry labelled $item? Word for word, because menu_pairs below cuts
# the item at the emphasis that closes it — so "Git Pane" is not allowed to pass as
# "Git", which is the whole point: a *renamed* entry is drift as surely as a removed one.
#
# A label's trailing parenthetical is a hint, not part of its name — "Column Editing
# (Ctrl+Shift+Drag)" is the Column Editing item — so a label is also tried without it.
proc menu_entry {menu item} {
	if {![winfo exists $menu]} { return 0 }
	set iw [menu_words $item]
	for {set i 0} {$i <= [$menu index end]} {incr i} {
		if {[catch {$menu entrycget $i -label} l] || $l eq ""} continue
		foreach cand [list $l [regsub { *\([^)]*\)$} $l ""]] {
			if {[menu_words $cand] eq $iw} { return 1 }
		}
	}
	return 0
}

# Each `▸` is checked on its own — "View ▸ Font & Zoom ▸ Font…" asks two questions, not
# one walk — because a path in a Markdown paragraph is routinely broken across a line,
# and because one long chain would swallow the prose between two unrelated paths and
# lose the second. Locally neither can happen: the text before a `▸` ends with the
# menu's name, the text after it begins with the entry's.
#
# Markdown emphasis is the item's right-hand boundary — ***View ▸ Theme…*** ends where
# the stars do — so the markers are not stripped but turned into a delimiter (\x01).
# That is what lets the label be matched exactly instead of as a prefix, and it means
# **every page must keep quoting its menu paths in emphasis**: an unmarked path runs on
# into its sentence and is reported here, which is the nudge to mark it up.
#
# Newlines become spaces first, so a path wrapped across two source lines is whole again.
proc menu_pairs {text} {
	set flat [string map [list * \x01 ` \x01 \n " "] $text]
	set out {}
	set fields [split [string map [list " ▸ " \x02] $flat] \x02]
	for {set i 0} {$i < [llength $fields] - 1} {incr i} {
		# The menu is named by the END of this field; longest name first, so
		# "Font & Zoom" wins over a bare "Zoom".
		set lw [menu_words [string map [list \x01 " "] [lindex $fields $i]]]
		set name ""
		for {set n 4} {$n >= 1} {incr n -1} {
			if {[llength $lw] < $n} continue
			set cand [join [lrange $lw end-[expr {$n - 1}] end]]
			if {[info exists ::menus($cand)]} { set name $cand ; break }
		}
		if {$name eq ""} continue
		# The item is what follows, up to the emphasis that closes it. Leading markers are
		# the nesting in **View ▸ *Theme…*** and are skipped; a field carrying no marker at
		# all is a whole path element ("Font & Zoom", sitting between two ▸).
		set next [string trimleft [lindex $fields [expr {$i + 1}]] \x01]
		lappend out [list $name $::menus($name) \
			[string trim [lindex [split $next \x01] 0]]]
	}
	return $out
}

# The manual, plus the root documents written for a user. AGENTS.md, ROADMAP.md, PITCH.md
# and CAVEATS.md are deliberately absent: a design log names retired menus (D74's Tabs
# cascade, D92's theme dropdown) and planned ones (Help ▸ Contents…) on purpose, and
# holding them to what exists today would make them lie about their own history.
set ::menu_docs {}
foreach p [lsort [glob -nocomplain -directory $::docs *.md]] { lappend ::menu_docs $p }
foreach f {README.md INSTALL.md WINDOWS.md CONTRIBUTING.md} {
	lappend ::menu_docs [file join $::docs .. $f]
}

set stale {}
foreach p $::menu_docs {
	set page [file tail $p]
	foreach pair [menu_pairs [slurp $p]] {
		lassign $pair name menu item
		if {[lsearch -exact $::datamenus $menu] >= 0} continue
		if {[lsearch -exact $::notrio "$name ▸ $item"] >= 0} continue
		if {![menu_entry $menu $item]} {
			lappend stale "$page: “$name ▸ $item” (no such entry in $menu)"
		}
	}
}
ok "every menu path in the docs exists" $stale {}

# --- 7. every menu the docs NAME exists too -----------------------------------
#
# Check 6's blind spot, and the one that actually bit: a menu named as prose carries no
# `▸` for it to see. "The **Tabs** menu" outlived the menu itself by three decisions in
# WINDOWS.md, and nothing but a reader was going to catch it — so the same register row
# has to cover both ways a document can name a menu, or half of it is unguarded.
#
# The rule is narrow on purpose: a **capitalised** word before "menu"/"submenu"/
# "cascade" is a name, and must be one rio has. Everything else is English and is left
# alone — "the row menu", "its pane's menu", "a right-click menu" never reach the check,
# because a name is capitalised and a description is not.
set ::prose_not {
	The A An This That These Those Its Their Each Every Same Other Both
	Right-click Context Pop-up
}
# ...and the compounds where "menu" is the adjective rather than the thing.
set ::prose_tail {path paths bar entry entries item items label labels}

proc menu_prose {text} {
	set ws [menu_words [string map [list * " " ` " " \n " "] $text]]
	set out {}
	for {set i 1} {$i < [llength $ws]} {incr i} {
		if {[lsearch -exact {menu submenu cascade} \
			[string tolower [lindex $ws $i]]] < 0} continue
		if {[lsearch -exact $::prose_tail \
			[string tolower [lindex $ws [expr {$i + 1}]]]] >= 0} continue
		if {[lindex $ws [expr {$i - 2}]] eq "▸"} continue ;# a path — check 6 owns it
		set name [lindex $ws [expr {$i - 1}]]
		if {![string match {[A-Z]*} $name]} continue
		if {[lsearch -exact $::prose_not $name] >= 0} continue
		# Longest name first, so "Font & Zoom" wins over a bare "Zoom".
		for {set n 4} {$n >= 2} {incr n -1} {
			if {$i < $n} continue
			set cand [join [lrange $ws [expr {$i - $n}] [expr {$i - 1}]]]
			if {[info exists ::menus($cand)]} { set name $cand ; break }
		}
		if {![info exists ::menus($name)]} { lappend out $name }
	}
	return $out
}

set gone {}
foreach p $::menu_docs {
	set page [file tail $p]
	foreach name [menu_prose [slurp $p]] {
		lappend gone "$page: the “$name” menu (rio has no such menu)"
	}
}
ok "every menu the docs name exists" $gone {}

# --- 8. the help viewer can actually reach the manual ------------------------
#
# Checks 1 and 2 hold the manual together as FILES; this one holds the code that reads it
# (D99). Two things can silently break the viewer while every page stays perfect: the
# directory moves out from under `help_dir` (a packaging change), or index.md grows a
# contents shape `help_contents` cannot parse — turn that list into a table and the parser
# returns nothing, the window opens empty, and no other check notices.
#
# So: the code's idea of where docs/ is must be the real docs/, and the topics it offers
# must be exactly the pages index.md lists — the same both-directions rule as check 1, one
# layer up.

ok "the viewer looks where the manual is" [help_dir] $::docs

set offered {}
foreach e [help_contents] { lappend offered [lindex $e 2] }
ok "the viewer's contents is not empty" [expr {[llength $offered] > 1}] 1

set unreachable {}   ;# a page index.md lists that the viewer never offers
foreach t $listed {
	if {[lsearch -exact $offered $t] < 0} { lappend unreachable $t }
}
ok "the viewer offers every listed page" $unreachable {}

set invented {}      ;# a topic the viewer offers that isn't a page
foreach t $offered {
	if {![file exists [file join [help_dir] $t]]} { lappend invented $t }
}
ok "every topic the viewer offers exists" $invented {}

# Every entry carries the section it sits under, so the window can group them the way the
# contents page does — an entry parsed out of its heading would land in the wrong group.
set unsectioned {}
foreach e [help_contents] {
	if {[lindex $e 0] eq "" || [lindex $e 1] eq ""} { lappend unsectioned $e }
}
ok "every topic has a section and a title" $unsectioned {}

puts [expr {$::fails ? "FAILED ($::fails)" : "ALL PASS"}]
exit [expr {$::fails ? 1 : 0}]

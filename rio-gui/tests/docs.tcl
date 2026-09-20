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

# Compared as WHOLE paths below the root, not as first segments. The first version reduced
# every row to its top directory, so everything under `agent/` was one entry: a new file
# there (agent.conf, D110; providers/<name>.conf, D106) passed as documented while the
# table never mentioned it. Each producer is now the proc that builds one concrete file or
# directory; a per-provider or per-key file is built for a sample name, and the table
# writes that name as `<name>` or `*`.

# proc to call -> which XDG root its result hangs under
set producers {
	{prefs_path}                                 config
	{keys_path}                                  config
	{sources_path}                               config
	{repo_keys_path}                             config
	{rio::tls::exceptions_path}                  config
	{hl_user_dir}                                config
	{modes_user_dir}                             config
	{lindex [rio::theme::searchdirs] 0}          config
	{rio::agent::prompt::path base}              config
	{rio::agent::prompt::path plan}              config
	{rio::agent::prompt::path system}            config
	{rio::agent::prompt::path provider claude}   config
	{rio::agent::allow::_global_file}            config
	{rio::agent::allow::_provider_file claude}   config
	{rio::agent::settings::path claude}          config
	{rio::tls::settings_path}                    config
	{ledger_path}                                data
	{rio::secret::_path claude}                  data
	{rio::workspace::_dir}                       data
	{rio::provider::_dir}                        data
}

# The two XDG tables, sliced apart so a config path can't satisfy a data row. Each cell
# becomes a `string match` pattern: a trailing / dropped, and `<name>` read as `*`.
proc doc_cells {text from to} {
	set body [string range $text [string first $from $text] \
		[expr {[string first $to $text] - 1}]]
	set out {}
	foreach {_ cell} [regexp -all -inline -line {^\| `([^`]+)` \|} $body] {
		lappend out [regsub -all {<[^>]*>} [string trimright $cell /] *]
	}
	return [lsort -unique $out]
}
set doc(config) [doc_cells $prefs "**Config —" "**Data —"]
set doc(data)   [doc_cells $prefs "**Data —"   "**Project-local"]
set xdgroot(config) [file join $::env(XDG_CONFIG_HOME) rio]
set xdgroot(data)   [file join $::env(XDG_DATA_HOME) rio]

set missing {}
set produced(config) {} ; set produced(data) {}
foreach {call root} $producers {
	set p [uplevel #0 $call]
	set pre "$xdgroot($root)/"
	if {[string first $pre $p] != 0} {
		lappend missing "$root: $call built $p, outside $xdgroot($root)"
		continue
	}
	set rel [string range $p [string length $pre] end]
	lappend produced($root) $rel
	set found 0
	foreach pat $doc($root) {
		if {[string match $pat $rel]} { set found 1 ; break }
	}
	if {!$found} { lappend missing "$root/$rel ($call)" }
}
ok "every config & data path is documented" $missing {}

set orphaned {}
foreach root {config data} {
	foreach pat $doc($root) {
		set built 0
		foreach rel $produced($root) {
			if {[string match $pat $rel]} { set built 1 ; break }
		}
		if {!$built} { lappend orphaned "$root/$pat" }
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

# --- 9. every #anchor a page links to is a heading rio can find ---------------
#
# Check 2 stops at the filename, because until D100 an anchor was decoration — the viewer
# showed the source and scrolled nowhere. Now it is a destination, and it is reached by
# slug: the author writes `preferences.md#where-everything-lives` and rio derives that
# string back out of the heading text. Two ways for that to rot, and this catches both —
# an anchor that never named a heading, and a heading whose wording was edited afterwards
# (which changes its slug and silently drops the link on the floor).
#
# It checks the CODE's slugs, not a second copy of GitHub's rule: help_slug and help_blocks
# are what the viewer will use, so a change in either shows up here.

proc doc_anchors {path} {
	set out {}
	foreach blk [help_blocks [slurp $path]] {
		if {[lindex $blk 0] eq "heading"} { lappend out [help_slug [lindex $blk 2]] }
	}
	return $out
}

set anchored {}   ;# {page link target-file slug}
foreach p $pages {
	set text [slurp [file join $::docs $p]]
	foreach {_ target} [regexp -all -inline {\]\(([^)]+)\)} $text] {
		if {[regexp {^[a-z][a-z0-9+.-]*:} $target]} continue
		if {![regexp {^([^#]*)#(.+)$} $target -> file slug]} continue
		if {$file eq ""} { set file $p }
		lappend anchored [list $p $target $file $slug]
	}
}
ok "the manual links to headings at all" [expr {[llength $anchored] > 3}] 1

set lost {}
foreach a $anchored {
	lassign $a page link file slug
	set path [file join $::docs $file]
	if {![file exists $path]} continue       ;# check 2 owns a missing file
	if {[lsearch -exact [doc_anchors $path] $slug] < 0} { lappend lost "$page -> $link" }
}
ok "every #anchor names a real heading" $lost {}

# --- 10. the editor's context menu and the page that lists it ------------------

# editor.md enumerates the right-click menu (D108), which is a list the CODE decides
# — a derived fact, so it gets a guard like the keymap and prefs tables above, and
# for the same reason: nothing fails when a menu entry is added, renamed or dropped
# and the page keeps the old wording.
#
# Behaviour, not source text: the REAL menu is built here, the way the right-click
# builds it. With no selection, so every label is in its static form — the Search
# entry quotes the selection when there is one, and that variable half belongs to
# `context_menu.tcl`, which tests it against the rule rather than against a string.
#
# Both directions, and the convention that makes the second one possible: inside
# that section **bold marks a menu entry**, so an entry the page forgot and a name
# the page invented are both caught. Bold anything else there and this check will
# say so.
#
# The menu is built twice. This suite runs with Echo, and Change with Agent… (D113)
# appears only while a real provider is selected — built once, the page could invent
# that entry or forget it and nothing would notice. So the second build names a
# provider other than Echo and turns the preference on; the union of both builds is
# what the page must list.
proc ctx_labels {} {
	menu .docsmenu -tearoff 0
	[gget 0 path] tag remove sel 1.0 end
	editor_context_build .docsmenu 0
	set out {}
	for {set i 0} {$i <= [.docsmenu index end]} {incr i} {
		if {[.docsmenu type $i] eq "separator"} continue
		lappend out [.docsmenu entrycget $i -label]
	}
	destroy .docsmenu
	return $out
}
set ::ctxlabels [ctx_labels]
set saved_ctx [list $::agent_provider $::agent_selection_menu]
set ::agent_provider docs-real-provider ; set ::agent_selection_menu 1
set ctxreal [ctx_labels]
lassign $saved_ctx ::agent_provider ::agent_selection_menu
ok "a real provider adds context-menu entries" [expr {[llength $ctxreal] > [llength $::ctxlabels]}] 1
set ::ctxlabels [lsort -unique [concat $::ctxlabels $ctxreal]]
ok "the context menu has entries" [expr {[llength $::ctxlabels] > 5}] 1

set ed [slurp [file join $::docs editor.md]]
set sect ""
regexp {\n## The right-click menu\n(.*?)(?:\n## |\Z)} $ed -> sect
ok "editor.md has the right-click section" [expr {$sect ne ""}] 1

set bolded [lsort -unique [lmap {_ b} [regexp -all -inline {\*\*([^*]+)\*\*} $sect] {set b}]]

set missing {}
foreach l $::ctxlabels {
	if {[lsearch -exact $bolded $l] < 0} { lappend missing $l }
}
ok "every context-menu entry is documented" $missing {}

set invented {}
foreach b $bolded {
	if {[lsearch -exact $::ctxlabels $b] < 0} { lappend invented $b }
}
ok "the section names no entry the menu lacks" $invented {}

# --- 11. every "Preferences ▸ Category ▸ Control" the docs quote is real ------------
#
# Check 6's twin for the Preferences window, which check 6 deliberately skips: its paths
# are a window's, not the menubar's. They drift the same way. D114 moved Accepted
# certificates… from Extensions to a new Network category, and the old path sat in two
# topics with every check green.
#
# Behaviour, not source text: open the real window and read its category list and the
# -text of every control (checkbutton, radiobutton, button) in each category's pane. A
# control's trailing parenthetical is a hint, as in check 6, so the label is also tried
# without it. A control that is installed data (`<provider>` API Key…) is taken on trust.
#
# The category is the word after "Preferences ▸ "; the control, when a second ▸ follows,
# runs to the emphasis that closes it — the same convention check 6 depends on.
preferences_window
update idletasks
set ::prefcats {}
for {set i 0} {$i < [.prefs.cats size]} {incr i} { lappend ::prefcats [.prefs.cats get $i] }
ok "the Preferences window has categories" [expr {[llength $::prefcats] > 3}] 1

proc pref_controls {w} {
	set out {}
	foreach c [winfo children $w] {
		if {[winfo class $c] in {Button Checkbutton Radiobutton}} {
			lappend out [$c cget -text]
		}
		lappend out {*}[pref_controls $c]
	}
	return $out
}

proc pref_paths {text} {
	# A path wrapped across source lines, list indentation and all, is whole again.
	set flat [regsub -all {\s+} [string map [list * \x01 ` \x01] $text] " "]
	set out {}
	foreach {_ rest} [regexp -all -inline {Preferences ▸ ([^\n]*?)(?=Preferences ▸ |$)} $flat] {
		if {![regexp {^([A-Z][A-Za-z]*)(.*)$} $rest -> cat tail]} {
			lappend out [list "" ""]
			continue
		}
		set item ""
		if {[string match " ▸ *" $tail]} {
			set item [string trim [lindex [split [string trimleft [string range $tail 3 end] \x01] \x01] 0]]
			set item [string trim $item "\"“”"]
		}
		lappend out [list $cat $item]
	}
	return $out
}

set stale {}
foreach p $::menu_docs {
	set page [file tail $p]
	foreach pair [pref_paths [slurp $p]] {
		lassign $pair cat item
		if {[lsearch -exact $::prefcats $cat] < 0} {
			lappend stale "$page: “Preferences ▸ $cat” (no such category)"
			continue
		}
		if {$item eq "" || [string match *<* $item]} continue
		set iw [menu_words $item]
		set found 0
		foreach l [pref_controls .prefs.body.[string tolower $cat]] {
			foreach cand [list $l [regsub { *\([^)]*\)$} $l ""]] {
				if {[menu_words $cand] eq $iw} { set found 1 }
			}
		}
		if {!$found} { lappend stale "$page: “Preferences ▸ $cat ▸ $item” (no such control)" }
	}
}
ok "every Preferences path in the docs exists" $stale {}
destroy .prefs

# --- 12. the menus outside the editor, and the page that lists them ------------
#
# Check 10's twin for D115. The editor's menu is one list the code decides; the other
# two are `view_menu_build` (read-only text: the agent log, a diff, the compare panes,
# a plan, this manual) and `input_menu_build` (every entry/text outside the editor).
# getting-started.md writes them down, which makes them a derived fact with the same
# failure mode: an entry added, renamed or dropped and the page keeps the old wording.
#
# Behaviour, not source text: the two builders are run against fixtures of this test's
# own — a disabled text and a bare entry — so the check never depends on what some pane
# happens to hold, and the labels come from the real menu widget.
#
# Both directions, on the convention check 10 established: inside *Right-click menus*
# **bold marks a menu entry**, and nothing else. Emphasise a surface name there and this
# check will call it an invented entry — italics are what that section uses for them.
proc bare_labels {kind w} {
	catch {destroy .docsbare}
	menu .docsbare -tearoff 0
	${kind}_menu_build .docsbare $w
	set out {}
	for {set i 0} {$i <= [.docsbare index end]} {incr i} {
		if {[.docsbare type $i] eq "separator"} continue
		lappend out [.docsbare entrycget $i -label]
	}
	destroy .docsbare
	return $out
}
text  .docsview -state disabled
entry .docsinput
entry .docsmask -show •   ;# the provider API-key field's shape (D26): no Cut, no Copy
.docsinput insert 0 "text" ; .docsmask insert 0 "secret"
set ::barelabels [lsort -unique \
	[concat [bare_labels view .docsview] [bare_labels input .docsinput]]]
set ::masklabels [lsort -unique [bare_labels input .docsmask]]
destroy .docsview .docsinput .docsmask
ok "the bare-widget menus have entries" [expr {[llength $::barelabels] > 2}] 1
ok "a read-only view offers fewer than an editable field" \
	[expr {[llength [bare_labels view [text .docsview -state disabled]]] \
		< [llength [bare_labels input [entry .docsinput]]]}] 1
destroy .docsview .docsinput

set gs [slurp [file join $::docs getting-started.md]]
set sect ""
regexp {\n## Right-click menus\n(.*?)(?:\n## |\Z)} $gs -> sect
ok "getting-started.md has the right-click section" [expr {$sect ne ""}] 1

proc md_bold {text} {
	return [lsort -unique [lmap {_ b} [regexp -all -inline {\*\*([^*]+)\*\*} $text] {set b}]]
}
set bolded [md_bold $sect]

set missing {}
foreach l $::barelabels {
	if {[lsearch -exact $bolded $l] < 0} { lappend missing $l }
}
ok "every entry of the menus outside the editor is documented" $missing {}

set invented {}
foreach b $bolded {
	if {[lsearch -exact $::barelabels $b] < 0} { lappend invented $b }
}
ok "the section names no entry those menus lack" $invented {}

# The masked field is the one place the list is deliberately shorter, so the page's
# paragraph about it is held against that menu exactly — a Cut or a Copy appearing
# there, or the paragraph claiming one, is the drift this catches.
set maskpar ""
foreach par [split [string map [list "\n\n" \x02] $sect] \x02] {
	if {[string match *API-key* $par]} { set maskpar $par }
}
ok "the section covers the masked field" [expr {$maskpar ne ""}] 1
ok "the masked field's entries are the ones documented" [md_bold $maskpar] \
	[lsort -unique $::masklabels]

# --- 13. the pre-seeded repository URL the docs quote is the one rio seeds ----
#
# ::default_repo is written into a fresh sources.list on a true first run (D39), and it
# is a user-visible string: the manual tells the reader which URL will be there and how
# to remove it. It is also the kind of fact that drifts silently — the URL moved from
# .../rio to .../extensions once already, and a reader who copies the stale one adds a
# repository that 404s while every page still reads perfectly.
#
# Derived from ::default_repo, never spelled out here: the host comes out of the
# constant, every inline-code URL on that host across the manual and the user-facing
# root documents is collected, and the set must be exactly {the default}. Both
# directions — an old path left behind is a second entry, and dropping the mention
# altogether leaves an empty set.
set ::rhost ""
regexp {^https?://([^/]+)} $::default_repo -> ::rhost
ok "the default repo has a host" [expr {$::rhost ne ""}] 1

set quoted {}
foreach p $::menu_docs {
	foreach {_ u} [regexp -all -inline "`(https?://[string map {. \\.} $::rhost]\[^`\]*)`" \
		[slurp $p]] {
		lappend quoted $u
	}
}
ok "the pre-seeded repository URL the docs quote" [lsort -unique $quoted] \
	[list $::default_repo]

# --- 14. the words a repository's signature makes rio say ---------------------
#
# D118 put three user-visible vocabularies on the screen and all three are quoted in
# extensions.md: the one-word mark every version line ends in (`sig_mark`), and the
# phrase a refused source carries on its row (`dead_phrase`). They are the same kind
# of derived fact as the keymap table — a handful of strings a reader matches against
# what rio actually printed, so a reworded phrase leaves the manual describing a
# message nobody will ever see, and it reads perfectly while doing it.
#
# Behaviour, not source text: every phrase below comes out of calling the proc. The
# code NAMES are enumerated from the live proc body (`info body`) rather than listed
# here, so a refusal added to rio without a row in the manual fails this check instead
# of waiting to be noticed; the body is only a source of candidates, and each one is
# then put through dead_phrase to get the words. A comment cannot slip in — it would
# have to be shaped like a switch arm and survive the call.

# The first column of the tables under a `### ` heading, as a set. The section ends at
# the next `### `, so renaming a LATER heading can't silently widen or empty a table
# this check reads — only the heading named here matters, and if that one is gone the
# empty set fails the comparison rather than passing on the rest of the page.
proc md_col1 {text from} {
	set a [string first $from $text]
	if {$a < 0} { return {} }
	set body [string range $text [expr {$a + [string length $from]}] end]
	set b [string first "\n### " $body]
	if {$b >= 0} { set body [string range $body 0 $b] }
	set out {}
	foreach {_ cell} [regexp -all -inline -line {^\| `([^`]+)` \|} $body] { lappend out $cell }
	return [lsort -unique $out]
}

set ext [slurp [file join $::docs extensions.md]]

# The mark a variant line ends in. Held as a set, both directions at once: the table
# in "What you see" must be exactly the words sig_mark produces.
set marks {}
foreach state {signed unverified unsigned} { lappend marks [sig_mark $state] }
ok "a repository is marked three ways" [llength [lsort -unique $marks]] 3
ok "extensions.md's marks are the ones rio prints" \
	[md_col1 $ext "### What you see"] [lsort -unique $marks]

# Why a source produced nothing, in the few words its row has. `dead_phrase` answers
# for a code it doesn't know too, so that default is exercised alongside the arms.
set codes {""}
foreach {_ code} [regexp -all -inline -line {^\s+([a-z_]+)\s+\{ return} [info body dead_phrase]] {
	lappend codes $code
}
ok "a refusal has more than one phrase" [expr {[llength $codes] > 4}] 1

set unsaid {}
foreach code $codes {
	if {[string first [dead_phrase $code] $ext] < 0} { lappend unsaid "$code: [dead_phrase $code]" }
}
ok "extensions.md names every refusal a source can get" $unsaid {}

set phrases {}
foreach code $codes { lappend phrases [dead_phrase $code] }
set invented {}
foreach cell [md_col1 $ext "### When rio refuses a signed repository"] {
	if {[lsearch -exact $phrases $cell] < 0} { lappend invented $cell }
}
ok "the refusal table quotes no phrase rio never prints" $invented {}

# --- 15. every door out of the Preferences window is named in the manual ------
#
# Check 11 in reverse, and the direction that was missing. Check 11 holds the paths the
# docs quote against the real window; nothing held the window against the docs, so a new
# button could land with every check green while the manual went on describing the old
# way of doing that job. That is what D118's *Repository signing keys…* did: two topics
# kept saying the only way to take a key back was to edit a file by hand.
#
# Buttons only. A checkbutton is a setting, and check 4 already holds prefs.json's keys
# against the page; a button opens a whole window, which is a feature the manual has to
# name. WHERE it names it is the writer's business — a Preferences path, or the menu
# that opens the same window — so this matches the label in the prose, not a path.
#
# Behaviour, not source text: the labels come off the real widgets. Two are skipped
# because they are data rather than rio's vocabulary — the theme button carries the
# current theme's name through -textvariable, and a provider's `<name>` API Key… button
# exists only once that provider is installed.
preferences_window
update idletasks
proc pref_doors {w} {
	set out {}
	foreach c [winfo children $w] {
		if {[winfo class $c] eq "Button" && [$c cget -textvariable] eq ""} {
			set l [$c cget -text]
			if {$l ne "" && ![string match *<* $l]} { lappend out $l }
		}
		lappend out {*}[pref_doors $c]
	}
	return $out
}
set doors {}
foreach cat $::prefcats { lappend doors {*}[pref_doors .prefs.body.[string tolower $cat]] }
ok "the Preferences window has doors to other windows" [expr {[llength $doors] > 5}] 1

# Emphasis and inline code dropped, every run of whitespace one space: a label wrapped
# across two source lines is still the label.
set flat {}
foreach p $::menu_docs {
	lappend flat [regsub -all {\s+} [string map [list * "" ` ""] [slurp $p]] " "]
}
set unnamed {}
foreach l [lsort -unique $doors] {
	set found 0
	foreach t $flat { if {[string first $l $t] >= 0} { set found 1 ; break } }
	if {!$found} { lappend unnamed $l }
}
ok "every Preferences button is named in the docs" $unnamed {}
destroy .prefs

# --- 16. the words the two signing-key windows put on screen ------------------
#
# D119 made confirming a repository's key something the user does, and the manual now
# walks a reader through two windows by name: the review dialog behind a refused row —
# which has two forms, a first sight and a rotation, differing in title and in the
# button that grants trust — and the `(built in)` row in the keys window, the one row
# whose Forget does something a reader has to be told about before they press it.
#
# Check 15 cannot reach either: neither is the Preferences window, they are what its
# button and a refused row open. So a renamed button or a reworded row annotation
# would leave the manual sending a reader after a control that is not there, with
# every other check green — the same failure check 15 was written for, one door along.
#
# Behaviour, not source text: both windows are really built and every string is read
# off the live widget. Both block in tkwait, so each is driven from the event loop and
# closed again, as rio-gui/tests/repos.tcl drives them. The poll waits for what the
# check reads rather than for the toplevel, because filling either window asks the
# core for a fingerprint and that pumps the event loop mid-build.
proc dlg_drive {ready script} { after 1 [list dlg_poll $ready $script 0] }
proc dlg_poll {ready script tries} {
	if {![uplevel #0 [list expr $ready]] && $tries < 400} {
		after 10 [list dlg_poll $ready $script [incr tries]]
		return
	}
	uplevel #0 $script
}

set ::keysave $::repo_keys
set ::k1 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdocsonedocsonedocsonedocsonedocs"
set ::k2 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdocstwodocstwodocstwodocstwodocs"

# The review dialog: its title, and both buttons. Go Back closes it, so nothing is
# ever trusted here — the drive destroys the window without choosing.
proc key_dialog_words {url key} {
	set ::kwords {}
	dlg_drive {[winfo exists .extkey.btns.trust]} {
		set ::kwords [list [wm title .extkey] [.extkey.btns.trust cget -text] \
			[.extkey.btns.back cget -text]]
		destroy .extkey
	}
	extw_key_review $url $key
	return $::kwords
}
set ::repo_keys {}
set firstsight [key_dialog_words http://docs.example/repo $::k1]
dict set ::repo_keys [source_key http://docs.example/repo] \
	[dict create key $::k1 trusted 2026-01-01 forgotten ""]
set rotation [key_dialog_words http://docs.example/repo $::k2]
set ::repo_keys $::keysave
ok "the signing-key dialog has two forms, and nothing was trusted to get them" \
	[list [expr {[lindex $firstsight 0] ne [lindex $rotation 0]}] \
		[expr {[lindex $firstsight 1] ne [lindex $rotation 1]}] \
		[repo_key_of http://docs.example/repo]] {1 1 {}}

# The keys window's annotation for rio's own row, in both of its states. Read out of
# the row text, so it is the string a reader compares against what they see.
proc keys_row_marks {} {
	set ::krows {}
	dlg_drive {[winfo exists .repokeys.body.list] && [.repokeys.body.list size] > 0} {
		set ::krows [.repokeys.body.list get 0 end]
		destroy .repokeys
	}
	repo_keys_dialog
	set out {}
	foreach line $::krows {
		if {[regexp {\((built in[^)]*)\)} $line -> m]} { lappend out $m }
	}
	return $out
}
set ::srcsave [sources_load]
sources_save [list $::default_repo]
set ::repo_keys {}
set builtin [keys_row_marks]
dict set ::repo_keys [source_key $::default_repo] \
	[dict create key "" trusted "" forgotten 2026-01-01]
set withdrawn [keys_row_marks]
sources_save $::srcsave
set ::repo_keys $::keysave
ok "the keys window marks rio's own row, and its withdrawal" \
	[concat $builtin $withdrawn] {{built in} {built in, withdrawn}}

# Emphasis and inline code dropped, whitespace collapsed: a label wrapped across two
# source lines is still the label, as in check 15.
set docflat {}
foreach p $pages {
	lappend docflat [regsub -all {\s+} \
		[string map [list * "" ` ""] [slurp [file join $::docs $p]]] " "]
}
set unsaid {}
foreach s [concat $firstsight $rotation $builtin $withdrawn] {
	set found 0
	foreach t $docflat { if {[string first $s $t] >= 0} { set found 1 ; break } }
	if {!$found} { lappend unsaid $s }
}
ok "every word those two windows say is in the manual" $unsaid {}

# --- 17. the facts Help ▸ About rio puts on screen ----------------------------
#
# About is the one window that describes the copy in front of the reader rather than
# the project, and since D121 it is where the licence is legible without going back to
# a repository. getting-started.md tabulates its rows, so the table is a second home
# for a fact that lives in the dialog — the register's rule, and the reason for this
# check: a row added, renamed or reordered in rio leaves the manual describing a box
# nobody will see, and it reads perfectly while doing it.
#
# smoke.tcl holds the dialog's licence against the LICENSE file; this holds the manual
# against the dialog, so relicensing rio fails in code (smoke) and in prose (here).
#
# Behaviour, not source text: the box is really built and every string is read off the
# live label. It only informs — grab, but no tkwait — so it needs no driving, unlike
# check 16's two windows. Order matters and is compared: D121 appended License last so
# the positional assertions elsewhere kept their meaning, and the table reads top to
# bottom like the block does.

# The rows of the first table under a `## ` heading, in page order, as
# {first-column-code rest-of-row}. Like md_col1, the section ends at the next heading
# of its own level, so renaming a LATER one cannot widen this; renaming THIS one
# empties it and fails the comparison rather than passing on the rest of the page.
proc md_table_rows {text from} {
	set a [string first $from $text]
	if {$a < 0} { return {} }
	set body [string range $text [expr {$a + [string length $from]}] end]
	set b [string first "\n## " $body]
	if {$b >= 0} { set body [string range $body 0 $b] }
	set out {}
	foreach {_ cell rest} [regexp -all -inline -line {^\| `([^`]+)` \| (.*) \|$} $body] {
		lappend out [list $cell $rest]
	}
	return $out
}

about_dialog
update idletasks
set factk {} ; set factv {}
for {set r 0} {[winfo exists .about.facts.k$r]} {incr r} {
	lappend factk [.about.facts.k$r cget -text]
	lappend factv [.about.facts.v$r cget -text]
}
destroy .about
ok "the About box has a facts block" [expr {[llength $factk] > 3}] 1

set aboutrows [md_table_rows $gs "## Help, and which rio you are running"]
ok "getting-started.md lists the About box's rows, in order" \
	[lmap row $aboutrows {lindex $row 0}] $factk

# The one fact in that block whose value is rio's own vocabulary rather than this
# build's or this machine's: the licence name has to be the word the box shows, quoted
# as code so a reader matches it against the screen.
set lic [lindex $factv [lsearch -exact $factk License]]
ok "the About box names a licence" [expr {$lic ne ""}] 1
set licrow [lindex [lindex $aboutrows [lsearch -index 0 -exact $aboutrows License]] 1]
ok "the manual quotes the licence the About box shows" \
	[expr {[lsearch -exact [lmap {_ c} [regexp -all -inline {`([^`]+)`} $licrow] {set c}] \
		$lic] >= 0}] 1

# The page tells the reader rio is on `0.x` and what that means — early days, things may
# change (D123). That is a claim about the version, with a real expiry: it stops being
# true at 1.0.0, which is the one release most likely to go out with the paragraph still
# sitting there saying the opposite. So the page is held to the number rather than left
# to be noticed. The page must NOT state the version itself — a literal here would be a
# second home going stale at every release, which is why the prose names no number.
set on_zerox [string match "0.*" $rio::version]
ok "the manual's 0.x note matches the version" \
	[string match "*rio is on `0.x` on purpose*" $gs] [expr {$on_zerox ? 1 : 0}]
ok "…and the page quotes no version of its own" \
	[regexp {`[0-9]+\.[0-9]+\.[0-9]+} $gs] 0

puts [expr {$::fails ? "FAILED ($::fails)" : "ALL PASS"}]
exit [expr {$::fails ? 1 : 0}]

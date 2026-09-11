#!/usr/bin/env wish
#
# Headless test for the in-app help viewer (AGENTS.md D99): Help ▸ Contents… / F1 opens
# rio's own manual — the contents parsed from docs/index.md on the left, the selected
# topic's text on the right. docs.tcl (check 8) holds the DATA path — the resolver points
# at the real docs/ and offers exactly the pages index.md lists. This file holds the
# WINDOW: that it builds, that its rows carry the right topics, that picking one loads it,
# that a missing topic is reported instead of thrown, and that a second open raises the
# window rather than stacking another.
#
# Needs a DISPLAY (it builds a real toplevel). No files are opened through the core: the
# viewer reads docs/ off the GUI's own tree, which is the point of it (a remote core's
# docs/ is a different machine's).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/help.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII and the manual's agree. The guard every entry point carries (D54).
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs (D31)
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

# --- the door: a menu entry and a remappable command ---------------------------------
#
# F1 goes through ::keymap_default like every other chord (D23) rather than a hard-coded
# binding, so it shows up in the shortcuts editor and in keyboard.md — which is what makes
# docs.tcl's keymap check cover it.
ok "menu: Help carries Contents…"   [.m.help entrycget 0 -label] "Contents…"
ok "menu: About is still there"     [.m.help entrycget end -label] "About rio"
ok "keymap: help is a command"      [dict exists $::keymap_default help] 1
ok "keymap: F1 is its default"      [lindex [dict get $::keymap_default help] 0] F1
ok "keymap: it opens the viewer"    [lindex [dict get $::keymap_default help] 1] help_window

# --- opening it ----------------------------------------------------------------------

ok "closed: no window yet"          [winfo exists .help] 0
help_window
ok "open: the window exists"        [winfo exists .help] 1
ok "open: lands on the front page"  $::help_topic index.md
ok "open: the page has text"        [expr {[string length [.help.page.text get 1.0 end]] > 200}] 1
ok "open: the page is read-only"    [.help.page.text cget -state] disabled
ok "open: the footer names the file" [.help.foot.where cget -text] [file join docs index.md]

# --- the contents list ----------------------------------------------------------------
#
# rl_* indexes rows by LINE, so every line must be a row — section headings included, as
# unselectable ones. A heading that forgot its rl_row would slide every topic below it onto
# the wrong payload, which is why the row count and the line count are checked against each
# other rather than either alone.
set b .help.nav.list
# Each row inserted its own trailing newline, so the widget's last index sits one line past
# the last row — rows are lines 1..N and `end-1c` is line N+1.
set lines [expr {[lindex [split [$b index end-1c] .] 0] - 1}]
ok "list: one row per line"         [llength $::rl_rows($b)] $lines
ok "list: the front page leads"     [rl_payload $b 0] index.md

# Every topic index.md lists is a selectable row, and every section heading is not.
set topics {}
foreach e [help_contents] { lappend topics [lindex $e 2] }
set rows {} ; set headings 0
for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
	if {[rl_selectable $b $i]} { lappend rows [rl_payload $b $i] } else { incr headings }
}
ok "list: offers every topic"       [lsort -unique [lrange $rows 1 end]] [lsort -unique $topics]
ok "list: headings are inert"       [expr {$headings > 0}] 1

# --- picking a topic ------------------------------------------------------------------

# Row indices are the list's own, headings included — so look the topic up by payload
# rather than counting, which is what a reader clicking the row effectively does.
proc row_of {b file} {
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		if {[rl_payload $b $i] eq $file} { return $i }
	}
	return -1
}
set gi [row_of $b git.md]
ok "pick: git.md has a row"         [expr {$gi >= 0}] 1
rl_select $b $gi
ok "pick: the topic loaded"         $::help_topic git.md
ok "pick: its text is showing"      [.help.page.text get 1.0 1.end] "Git"
ok "pick: the footer followed"      [.help.foot.where cget -text] [file join docs git.md]
ok "pick: the row is selected"      $::rl_sel($b) $gi

# Reaching a topic any other way still syncs the list selection, so the two halves of the
# window can never disagree about what is on screen.
help_show keyboard.md
ok "show: selection follows"        $::rl_sel($b) [row_of $b keyboard.md]

# --- the renderer, as a function (D100) -------------------------------------------------
#
# help_blocks is pure — Markdown in, block descriptors out, no widget — so it is checked as
# a function. Hand-wrapped prose rejoining into one block is the load-bearing case: the
# manual is wrapped for an 80-column editor and this window has its own width.
set md "# Title\n\nA **bold** and *soft* line\nwrapped by hand.\n\n- one\n- two\n\n"
append md "```\nx=1\n```\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n> quoted\n"
set blocks [help_blocks $md]
ok "blocks: a heading knows its level" [lindex $blocks 0] {heading 1 Title}
ok "blocks: hand wraps rejoin"      [lindex $blocks 1 1] "A **bold** and *soft* line wrapped by hand."
ok "blocks: list items"             [lrange $blocks 2 3] {{item 0 • one} {item 0 • two}}
ok "blocks: fenced code is verbatim" [lindex $blocks 4] {code x=1}
ok "blocks: a table drops its rule" [lindex $blocks 5] {table {{A B} {1 2}}}
ok "blocks: a blockquote"           [lindex $blocks 6] {quote quoted}

proc styles {s} { set o {} ; foreach r [help_inline $s] { lappend o [lindex $r 1] } ; return $o }
proc texts  {s} { set o {} ; foreach r [help_inline $s] { lappend o [lindex $r 0] } ; return $o }
# The three star widths have to be told apart by their MARKER, not by a glob — every `*` in
# a glob pattern is a wildcard, so a glob reads `**s**` as the triple and eats a character
# off each end of the word. That bug shipped for exactly one run; this is its guard.
ok "inline: markers by width"       [styles {*i* **s** ***x***}] {em {} strong {} strongem}
ok "inline: and the text survives"  [texts  {*i* **s** ***x***}] {i { } s { } x}
ok "inline: code is literal"        [texts {`a *b* c`}] {{a *b* c}}
ok "inline: a link's title and target" \
	[lindex [help_inline {see [the editor](editor.md).}] 1] {{the editor} link editor.md}
ok "plain: markup measured off"     [help_plain {a **b** `c`}] {a b c}
ok "slug: GitHub's rule"            [help_slug {Where **everything** lives?}] where-everything-lives

# --- the renderer, on screen -------------------------------------------------------------

set t .help.page.text
help_show git.md
ok "paint: the title is a heading"  [llength [$t tag ranges h1]] 2   ;# one range, two indices
ok "paint: and lost its hashes"     [string match *#* [$t get 1.0 1.end]] 0
help_show keyboard.md
ok "paint: the chord table is one"  [expr {[llength [$t tag ranges table]] > 0}] 1
ok "paint: tables do not reflow"    [$t tag cget table -wrap] none
help_show getting-started.md
ok "paint: fenced code is marked"   [expr {[llength [$t tag ranges code]] > 0}] 1

# --- links a reader can follow ------------------------------------------------------------
#
# A click resolves through the L<n> tag sitting under the pointer, so that mapping — not a
# synthetic click, which needs a mapped window — is what is checked.
help_show index.md
ok "links: the contents page is full of them" [expr {$::help_link_n > 15}] 1
set ltag [lsearch -inline -glob [$t tag names [lindex [$t tag ranges link] 0]] L*]
ok "links: the tag carries a target" [info exists ::help_link($ltag)] 1
help_goto $::help_link($ltag)
ok "links: following one lands"     $::help_topic getting-started.md
help_history back
ok "history: back returns"          $::help_topic index.md
help_history forward
ok "history: and forward again"     $::help_topic getting-started.md
ok "history: the back button is live" [.help.foot.back cget -state] normal

# An anchor scrolls within the page it names; one rio cannot place leaves the reader where
# they are rather than guessing at a line.
help_goto preferences.md#where-everything-lives
ok "anchor: the right page"         $::help_topic preferences.md
ok "anchor: scrolled into it"       [expr {[lindex [$t yview] 0] > 0}] 1
ok "anchor: an unknown one holds still" [help_anchor_see no-such-heading] 0

# index.md's own table points at rio's other documents. They are rio's files too, so they
# open — but nothing outside the rio directory does, whatever a page asks for.
help_goto ../README.md
ok "outside docs/: a sibling opens" $::help_topic ../README.md
ok "outside docs/: named plainly"   [.help.foot.where cget -text] README.md
ok "outside docs/: no row is current" $::rl_sel($b) -1
ok "escape: an absolute path is refused" [help_path /etc/passwd] ""
ok "escape: climbing out is refused"     [help_path ../../../../etc/passwd] ""
ok "escape: a topic is not"              [help_path git.md] [file join [help_dir] git.md]

# --- searching the manual --------------------------------------------------------------
#
# help_search is a function over the real docs/ tree, so the needles here are taken FROM the
# manual at run time rather than typed in: the prose belongs to whoever maintains it, and a
# check that quotes a sentence goes stale the first time that sentence is reworded.

# A heading deep in a page — deep so that landing on it has to scroll.
set hd ""
foreach blk [help_blocks [help_slurp [file join [help_dir] preferences.md]]] {
	if {[lindex $blk 0] eq "heading" && [lindex $blk 1] == 2} { set hd [lindex $blk 2] }
}
set res [help_search $hd]
set slugs {}
foreach e $res { if {[lindex $e 0] eq "preferences.md"} { lappend slugs [lindex $e 2] } }
ok "search: a heading finds its own section" [expr {[help_slug $hd] in $slugs}] 1
ok "search: case folds"              [llength [help_search [string toupper $hd]]] [llength $res]
ok "search: index.md leads"          [lindex [lindex [help_search rio] 0] 0] index.md
ok "search: a needle nobody wrote"   [help_search zzqq-not-in-the-manual] {}
ok "search: an empty needle is none" [help_search "   "] {}

# Matching is done on the STRIPPED line, so markup the reader never sees cannot hide a word
# from them. The needle is one real line of the manual that carries bold in its middle; the
# second check is the proof, since that same needle is NOT in the source line.
set marked ""
foreach f [lsort [glob [file join [help_dir] *.md]]] {
	foreach line [split [help_slurp $f] \n] {
		if {[regexp {^[A-Za-z][^*`|]*\*\*[^*]+\*\*[^*]+$} $line]} { set marked $line ; break }
	}
	if {$marked ne ""} break
}
set needle [string trim [help_plain $marked]]
ok "search: markup does not hide a word" [expr {[llength [help_search $needle]] > 0}] 1
ok "search: the source line lacks it"    \
	[string first [string tolower $needle] [string tolower $marked]] -1

# And through the entry: results replace the contents, a row carries file AND heading,
# activating one lands there, and the page bands what was searched for.
.help.find.e delete 0 end ; .help.find.e insert end $hd ; help_find_changed
set found -1
for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
	if {[rl_payload $b $i] eq [list preferences.md [help_slug $hd]]} { set found $i ; break }
}
ok "find: a result row names file and heading" [expr {$found >= 0}] 1
rl_select $b $found
ok "find: activating it lands on the topic"    $::help_topic preferences.md
ok "find: and scrolls to the heading"          [expr {[lindex [$t yview] 0] > 0}] 1
ok "find: the page bands the matches"          [expr {[llength [$t tag ranges hit]] > 0}] 1

.help.find.e delete 0 end ; .help.find.e insert end zzqq-not-in-the-manual ; help_find_changed
ok "find: no matches says so"        [string match "No matches*" [$b get 1.0 1.end]] 1
ok "find: and that row is inert"     [rl_selectable $b 0] 0

.help.find.e delete 0 end ; help_find_changed
ok "find: clearing restores contents" [rl_payload $b 0] index.md
ok "find: and the bands are gone"     [llength [$t tag ranges hit]] 0

# --- a topic that isn't there ---------------------------------------------------------
#
# A partial install must not break the one window that would explain it: the failure is
# REPORTED in the page, naming the path it wanted.
help_show no-such-topic.md
ok "missing: reported, not thrown"  \
	[string match "*could not be read*no-such-topic.md*" [.help.page.text get 1.0 end]] 1
ok "missing: window still up"       [winfo exists .help] 1

# --- opening it again ------------------------------------------------------------------

help_window editor.md
ok "reopen: still one window"       [llength [lsearch -all -inline [winfo children .] .help]] 1
ok "reopen: showed the asked topic" $::help_topic editor.md

destroy .help
ok "close: window gone"             [winfo exists .help] 0
ok "close: topic cleared"           $::help_topic ""

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

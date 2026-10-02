# rio-gui/help.tcl — the help viewer: contents, search, the Markdown renderer.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The help viewer — Help ▸ Contents…, F1 (D99, D100). rio showing its own manual.
#
# The manual is `docs/`, one Markdown topic per file, and the filename IS the topic id
# (D91) — which is why this needs no index of its own: index.md is the contents, and the
# files are the topics. The window is the WinHelp shape: the contents on the left, the
# selected topic on the right. D99 put the Markdown SOURCE in that right pane; D100
# renders it — headings, tables, code, and links a reader can follow, with Back/Forward
# behind them, which is what makes the manual's own cross-references work as doors
# rather than as text describing a door. The Find box searches it (D100).
#
# The GUI reads these files ITSELF, off its own tree, rather than through `file.open`.
# Help is the GUI's own chrome, not project content: over a remote core (D29) the project
# lives on another machine, so asking the core for a manual page would open the SERVER's
# copy — a different rio's documentation — or nothing at all. The same reasoning that puts
# syntax/ and themes/ beside the code puts docs/ there — and since rio is deployed by
# cloning it, docs/ is already wherever the code is, with nothing to install separately.
# ---------------------------------------------------------------------------

# Where the shipped manual lives: beside the code, like syntax/ (hl_load) and themes/.
proc help_dir {} { return [file normalize [file join $::rio_dir .. docs]] }

# Read one manual file as UTF-8 whatever the system encoding is — these pages are full of
# the arrows and dashes a cp1252 read would mangle, and the manual is UTF-8 by rule (D21).
proc help_slurp {path} {
	set f [open $path r] ; fconfigure $f -encoding utf-8
	set t [read $f] ; close $f
	return $t
}

# The contents, read from index.md as {section title file} in document order. index.md's
# shape is the contract — `### Section` headings and `- [Title](topic.md)` entries under
# `## Contents` — the same shape docs.tcl already holds the page to, so the viewer and the
# guard agree on what a contents entry is. Links that leave docs/ (`../README.md`) are not
# topics: this window shows the manual, and the manual says where else to look.
proc help_contents {} {
	set idx [file join [help_dir] index.md]
	if {![file exists $idx]} { return {} }
	set out {} ; set inside 0 ; set section ""
	foreach line [split [help_slurp $idx] \n] {
		if {[regexp {^##\s+(.+?)\s*$} $line -> h]} {
			set inside [string equal $h "Contents"] ; continue
		}
		if {!$inside} continue
		if {[regexp {^###\s+(.+?)\s*$} $line -> s]} { set section $s ; continue }
		if {[regexp {^\s*-\s+\[([^\]]+)\]\(([^)#]+)\)} $line -> title target]} {
			if {[string match */* $target]} continue
			lappend out [list $section $title $target]
		}
	}
	return $out
}

set ::help_topic ""   ;# the topic the viewer is showing, "" while it is closed

# Open the viewer (or raise it) and show TOPIC, a docs/ filename. Non-modal and
# single-instance, the Extensions window's idiom (D39) — which is also what makes a later
# move into a dock site a re-host rather than a rewrite, if that is where help ends up.
proc help_window {{topic ""}} {
	set w .help
	if {[winfo exists $w]} {
		raise $w ; focus $w.nav.list
		if {$topic ne ""} { help_show $topic }
		return
	}
	toplevel $w
	wm title $w "rio Help"

	# Find: the Extensions window's header idiom — a filter entry that repaints the list
	# below it as you type (D39). The contents list answers "what is in the manual"; this
	# answers "where is the word", which is the other way a reader arrives at a page.
	frame $w.find
	label $w.find.l -text "Find:" -font RioUIFont
	entry $w.find.e -font RioUIFont -width 18
	ctx_bind_input $w.find.e   ;# (D115)
	pack $w.find.l -side left -padx {0 4}
	pack $w.find.e -side left
	bind $w.find.e <KeyRelease> help_find_changed
	# Escape clears the search rather than closing the window — but only while there IS
	# one, so a second Escape still leaves, which is what the key means everywhere else.
	bind $w.find.e <Escape> {
		if {[.help.find.e get] ne ""} { .help.find.e delete 0 end ; help_find_changed ; break }
	}

	# Contents: a rich list (D42) like the file and git panes, so it selects, hovers and
	# arrows exactly as the rest of rio's lists do. Section headings are rows too — not
	# selectable — because rl_* indexes rows by line, so every line must be one.
	frame $w.nav -borderwidth 2 -relief sunken
	text $w.nav.list -width 24 -height 26 -wrap none -state disabled -cursor arrow \
		-insertwidth 0 -takefocus 1 -borderwidth 0 -highlightthickness 0 -padx 2 -pady 2
	pack $w.nav.list -side left -fill both -expand 1
	rl_init $w.nav.list help_pick {} {}

	# The topic, rendered (D100). The pages are hand-wrapped for a text editor, but this
	# window reflows them to whatever width it has — so it wraps by word, and the two block
	# kinds that must NOT reflow (code and tables) opt out per tag. Those are also the only
	# reason there is a horizontal bar at all, which is why it auto-hides.
	frame $w.page -borderwidth 2 -relief sunken
	scrollbar $w.page.sb  -command {.help.page.text yview}
	scrollbar $w.page.hsb -orient horizontal -command {.help.page.text xview}
	text $w.page.text -width 80 -height 26 -wrap word -state disabled -cursor arrow \
		-insertwidth 0 -borderwidth 0 -highlightthickness 0 -padx 8 -pady 4 \
		-yscrollcommand {gridscroll .help.page.sb} \
		-xscrollcommand {gridscroll .help.page.hsb}
	ctx_bind_view $w.page.text   ;# Copy / Select All (D115)
	grid $w.page.text -row 0 -column 0 -sticky nsew
	grid $w.page.sb   -row 0 -column 1 -sticky ns
	grid $w.page.hsb  -row 1 -column 0 -sticky we
	grid rowconfigure    $w.page 0 -weight 1
	grid columnconfigure $w.page 0 -weight 1
	help_link_binds $w.page.text

	# Back/Forward: following a link is the one way to end up somewhere the contents list
	# cannot bring you back from (an anchor inside a topic, or a document outside the
	# manual), so the doors D100 opens come with the way back.
	frame $w.foot
	button $w.foot.back -text "◀" -font RioUIFont -command {help_history back}
	button $w.foot.fwd  -text "▶" -font RioUIFont -command {help_history forward}
	label $w.foot.where -anchor w -font RioUIFont   ;# the file being shown, so a reader
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.back  -side left -padx {0 2}
	pack $w.foot.fwd   -side left -padx {0 8}
	pack $w.foot.close -side right                  ;# can go find it on disk
	pack $w.foot.where -side left -fill x -expand 1

	grid $w.find -row 0 -column 0 -columnspan 2 -sticky we   -padx 8 -pady {8 0}
	grid $w.nav  -row 1 -column 0 -sticky nsew -padx {8 4} -pady {8 4}
	grid $w.page -row 1 -column 1 -sticky nsew -padx {0 8} -pady {8 4}
	grid $w.foot -row 2 -column 0 -columnspan 2 -sticky we -padx 8 -pady {0 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 1 -weight 1
	bind $w <Escape> [list destroy $w]
	bind $w <Alt-Left>  {help_history back}
	bind $w <Alt-Right> {help_history forward}
	bind $w <$::primary_mod-f> {focus .help.find.e ; .help.find.e selection range 0 end}
	bind $w <Destroy> {if {"%W" eq ".help"} {set ::help_topic "" ; set ::help_needle ""}}

	set ::help_back {} ; set ::help_fwd {} ; set ::help_needle ""
	help_restyle
	help_fill_contents
	help_show [expr {$topic ne "" ? $topic : "index.md"}]
	focus $w.nav.list
}

# Paint the contents list. index.md leads it under its own title: it is a topic like any
# other (the manual's front page), and the viewer would otherwise be the one reader who
# can never see it.
proc help_fill_contents {} {
	set b .help.nav.list
	rl_begin $b
	$b insert end "The rio manual\n" ; rl_row $b 1 index.md
	set section ""
	foreach e [help_contents] {
		lassign $e s title file
		if {$s ne $section} {
			set section $s
			$b insert end "$s\n" helpsect ; rl_row $b 0 ""
		}
		$b insert end "  $title\n" ; rl_row $b 1 $file
	}
	rl_end $b
}

# Selecting a row shows what it points at. A contents row's payload is a filename; a search
# result's is {file slug} — lassign reads both, since a one-element payload leaves the anchor
# empty, which is exactly "show this topic from the top".
proc help_pick {payload} {
	lassign $payload file anchor
	if {$file ne ""} { help_show $file $anchor }
}

# ---------------------------------------------------------------------------
# Searching the manual. This runs HERE, in the GUI, over the same files the viewer reads —
# not through the core's project.search. The core may be on another machine (D29), where
# docs/ is a different rio's manual or absent entirely; the reasoning that makes the viewer
# read its own tree makes the search read it too.
#
# It is deliberately small. The manual is fourteen files and about 50 KB, so a search is a
# re-read of all of them — no index to build, and nothing that can go stale. Matching is
# line by line rather than over help_blocks, because a result needs the HEADING a match sits
# under, which the lines still know and the joined blocks no longer do.
# ---------------------------------------------------------------------------

set ::help_needle ""   ;# the live search, "" when the contents list is showing

# Every heading with a match, as {file title slug heading hits}, in document order.
proc help_search {needle} {
	set needle [string tolower [string trim $needle]]
	if {$needle eq ""} { return {} }
	set out {}
	# index.md is a topic like any other here, and leads, exactly as it does in the contents.
	foreach e [linsert [help_contents] 0 [list "" "The rio manual" index.md]] {
		lassign $e -> title file
		set path [help_path $file]
		if {$path eq "" || [catch {help_slurp $path} md]} continue
		set sect $title ; set slug "" ; set hits 0
		foreach line [split [string map {\r ""} $md] \n] {
			if {[regexp {^#{1,6}[ \t]+(.+?)[ \t]*$} $line -> h]} {
				if {$hits} { lappend out [list $file $title $slug $sect $hits] }
				set sect [help_plain $h] ; set slug [help_slug $h] ; set hits 0
			}
			# Matched against the STRIPPED line, so markup the reader never sees cannot hide a
			# word from them: searching "wrap lines" finds `**Wrap Lines**`.
			if {[string first $needle [string tolower [help_plain $line]]] >= 0} { incr hits }
		}
		if {$hits} { lappend out [list $file $title $slug $sect $hits] }
	}
	return $out
}

# The results, in the contents list's own two-level shape: the topic's title as a heading
# row, its matching sections under it. The pane is narrow, so a row names its section and
# its count rather than quoting the line — the highlight on the page does that job.
proc help_fill_results {needle} {
	set b .help.nav.list
	rl_begin $b
	set hits [help_search $needle]
	if {![llength $hits]} {
		# Never a blank pane: a search that found nothing says so.
		$b insert end "No matches\n" helpsect ; rl_row $b 0 ""
		rl_end $b
		return
	}
	set last ""
	foreach h $hits {
		lassign $h file title slug sect n
		if {$file ne $last} {
			set last $file
			$b insert end "$title\n" helpsect ; rl_row $b 0 ""
		}
		$b insert end "  $sect  ($n)\n" ; rl_row $b 1 [list $file $slug]
	}
	rl_end $b
}

# The entry changed: swap the list between contents and results, and re-show the current
# topic so its highlight follows the needle. Unchanged text is ignored, so arrowing around
# inside the entry does not repaint anything.
proc help_find_changed {} {
	if {![winfo exists .help]} return
	set needle [string trim [.help.find.e get]]
	if {$needle eq $::help_needle} return
	set ::help_needle $needle
	if {$needle eq ""} { help_fill_contents } else { help_fill_results $needle }
	if {$::help_topic ne ""} { help_show $::help_topic $::help_anchor_now 0 }
}

# Band every occurrence of the needle in the rendered page. Landing on the right heading is
# only half an answer — this is the half that says where in it.
proc help_mark_hits {t needle} {
	$t tag remove hit 1.0 end
	if {$needle eq ""} return
	set n 0 ; set i 1.0
	while {[set i [$t search -nocase -count n -- $needle $i end]] ne "" && $n > 0} {
		$t tag add hit $i "$i + $n chars"
		set i "$i + $n chars"
	}
}

# ---------------------------------------------------------------------------
# The renderer (D100). Markdown in, a painted text widget out, in two halves that are
# deliberately separate: help_blocks turns a page into a list of block descriptors with no
# widget in sight (so it can be checked as a function, and so a later help search can walk
# the same structure), and help_paint puts those blocks on screen.
#
# It reads the slice index.md commits the manual to — headings, paragraphs, lists, links,
# bold/italic, inline code, fenced code, simple tables, blockquotes — and nothing else. A
# construct outside that slice is not an error here; it simply renders as the text it is,
# which is the honest failure for a viewer whose input is hand-written prose.
# ---------------------------------------------------------------------------

# A heading's anchor, GitHub's rule: lowercased, punctuation dropped, spaces hyphenated.
# The manual links to headings by that slug (`preferences.md#where-everything-lives`), so
# rio has to derive the same one the author typed — docs.tcl holds both ends to it.
proc help_slug {s} {
	set s [string tolower [help_plain $s]]
	regsub -all {[^a-z0-9 -]} $s "" s
	return [string map {" " -} [string trim $s]]
}

# Inline markup, as a list of {text style target} runs. style is "" | strong | em | strongem
# | code | link; target carries a link's destination. One alternation finds the next marker
# of any kind, so the scan is a handful of regexps per line rather than per character, and
# leftmost-longest picks *** over ** over * without needing the order spelled out.
proc help_inline {s} {
	set re {`[^`]+`|\*\*\*[^*]+\*\*\*|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]*\]\([^)]*\)}
	set out {}
	while {[regexp -indices $re $s m]} {
		lassign $m a b
		if {$a > 0} { lappend out [list [string range $s 0 $a-1] "" ""] }
		set tok [string range $s $a $b]
		# Matched by leading marker, with string compares rather than a glob: every `*` in a
		# glob pattern is a wildcard, so "starts with ***" cannot be written as one.
		if {[string index $tok 0] eq "`"} {
			lappend out [list [string range $tok 1 end-1] code ""]
		} elseif {[string index $tok 0] eq "\["} {
			regexp {^\[([^\]]*)\]\(([^)]*)\)$} $tok -> title target
			lappend out [list $title link $target]
		} elseif {[string range $tok 0 2] eq "***"} {
			lappend out [list [string range $tok 3 end-3] strongem ""]
		} elseif {[string range $tok 0 1] eq "**"} {
			lappend out [list [string range $tok 2 end-2] strong ""]
		} else {
			lappend out [list [string range $tok 1 end-1] em ""]
		}
		set s [string range $s $b+1 end]
	}
	if {$s ne ""} { lappend out [list $s "" ""] }
	return $out
}

# The same text with its markup taken off — what a reader sees. Column widths and anchor
# slugs both need the visible length, not the source's.
proc help_plain {s} {
	set out ""
	foreach run [help_inline $s] { append out [lindex $run 0] }
	return $out
}

# Close whatever block is open. Tcl has no closures, so the accumulator travels by name.
proc help_flush {outv textv kindv depthv markerv} {
	upvar 1 $outv out $textv text $kindv kind $depthv depth $markerv marker
	if {$text ne ""} {
		switch $kind {
			item    { lappend out [list item $depth $marker $text] }
			quote   { lappend out [list quote $text] }
			default { lappend out [list para $text] }
		}
	}
	set text "" ; set kind "" ; set depth 0 ; set marker ""
}

# One page as a list of blocks: {heading LEVEL text} {para text} {quote text}
# {item DEPTH MARKER text} {code text} {table ROWS} {rule}. Prose blocks arrive as ONE
# string with their source line breaks joined out — the manual is hand-wrapped for an
# 80-column editor and this window has its own width, so it re-wraps rather than inheriting
# someone else's margin. Code and tables keep their lines, which is the whole point of them.
proc help_blocks {md} {
	set out {} ; set text "" ; set kind "" ; set depth 0 ; set marker ""
	set lines [split [string map {\r ""} $md] \n]
	set n [llength $lines]
	for {set i 0} {$i < $n} {incr i} {
		set ln [lindex $lines $i]
		set bare [string trimleft $ln]

		if {[string match "```*" $bare]} {          ;# fenced code, verbatim to the closing fence
			help_flush out text kind depth marker
			set code {}
			for {incr i} {$i < $n} {incr i} {
				if {[string match "```*" [string trimleft [lindex $lines $i]]]} break
				lappend code [lindex $lines $i]
			}
			lappend out [list code [join $code \n]]
			continue                                 ;# the loop's own incr steps past the fence
		}
		if {$bare eq ""} { help_flush out text kind depth marker ; continue }
		if {[regexp {^(#{1,6})\s+(.*?)\s*$} $ln -> hashes htext]} {
			help_flush out text kind depth marker
			lappend out [list heading [string length $hashes] $htext]
			continue
		}
		if {[regexp {^(-{3,}|\*{3,}|_{3,})$} $bare]} {
			help_flush out text kind depth marker
			lappend out [list rule]
			continue
		}
		if {[string index $bare 0] eq "|"} {         ;# a table runs until a line that isn't one
			help_flush out text kind depth marker
			set rows {}
			for {} {$i < $n} {incr i} {
				set r [string trim [lindex $lines $i]]
				if {[string index $r 0] ne "|"} break
				set cells {}
				foreach c [split [string trim $r "|"] "|"] { lappend cells [string trim $c] }
				if {![help_table_sep $cells]} { lappend rows $cells }
			}
			incr i -1
			lappend out [list table $rows]
			continue
		}
		if {[regexp {^>\s?(.*)$} $bare -> qtext]} {
			if {$kind ne "quote"} { help_flush out text kind depth marker ; set kind quote }
			append text [expr {$text eq "" ? "" : " "}] $qtext
			continue
		}
		if {[regexp {^(\s*)([-*+]|\d+[.)])\s+(.*)$} $ln -> ind mk itext]} {
			help_flush out text kind depth marker
			set kind item
			set depth [expr {[string length $ind] / 2}]
			set marker [expr {[string is digit [string index $mk 0]] ? $mk : "•"}]
			set text $itext
			continue
		}
		# Anything else continues the open block — which is how a hand-wrapped paragraph,
		# or the second line of a list item, rejoins the sentence it belongs to.
		if {$kind eq ""} { set kind para }
		append text [expr {$text eq "" ? "" : " "}] [string trim $ln]
	}
	help_flush out text kind depth marker
	return $out
}

# Is this row a table's `| --- | --- |` rule? It carries alignment in Markdown; rio renders
# every column left-aligned, so it carries nothing here and is dropped — wherever it sits,
# since a row of nothing but dashes has no content to lose either way. A cell holding a
# lone `-` as a value is safe: the row is only dropped if EVERY cell is dashes.
proc help_table_sep {cells} {
	foreach c $cells { if {![regexp {^:?-+:?$} $c]} { return 0 } }
	return [llength $cells]
}

# Paint one run of inline markup. `mono` picks the fixed-pitch variants, which a table needs
# so that a bold cell still measures the same as a plain one and the columns stay lined up.
proc help_spans {t s blocktags {mono 0}} {
	foreach run [help_inline $s] {
		lassign $run text style target
		set tags $blocktags
		switch $style {
			strong   { lappend tags [expr {$mono ? "mstrong" : "strong"}] }
			em       { lappend tags [expr {$mono ? "mem" : "em"}] }
			strongem { lappend tags [expr {$mono ? "mstrongem" : "strongem"}] }
			code     { lappend tags tt }
			link     { set tag L[incr ::help_link_n($t)]
			           set ::help_link($t,$tag) $target
			           lappend tags link $tag }
		}
		$t insert end $text $tags
	}
}

# Put a page on screen. Records where each heading landed (::help_anchor) so a `#slug` link
# can scroll to it, and what each link points at (::help_link) so a click can follow it.
# Both are keyed by WIDGET: the plan view (D101) paints with the same renderer, and painting
# a plan must not cost an open manual page its anchors.
proc help_paint {t blocks} {
	array unset ::help_anchor "$t,*"
	array unset ::help_link "$t,*"
	set ::help_link_n($t) 0
	foreach blk $blocks {
		set kind [lindex $blk 0]
		switch $kind {
			heading {
				lassign $blk -> level htext
				set ::help_anchor($t,[help_slug $htext]) [$t index "end-1c"]
				help_spans $t $htext [list h[expr {$level > 3 ? 3 : $level}]]
				$t insert end "\n"
			}
			para  { help_spans $t [lindex $blk 1] para  ; $t insert end "\n" }
			quote { help_spans $t [lindex $blk 1] quote ; $t insert end "\n" }
			item {
				lassign $blk -> depth marker itext
				if {$depth > 3} { set depth 3 }
				$t insert end "$marker " [list li$depth listmark]
				help_spans $t $itext li$depth
				$t insert end "\n" li$depth
			}
			code { $t insert end "[lindex $blk 1]\n" code }
			rule { $t insert end "[string repeat ─ 40]\n" rule }
			table { help_paint_table $t [lindex $blk 1] }
		}
	}
}

# A table, padded into columns. Widths come from the VISIBLE text (help_plain), not the
# source, or a cell of `code` would reserve room for its backticks.
proc help_paint_table {t rows} {
	set w {}
	foreach row $rows {
		for {set i 0} {$i < [llength $row]} {incr i} {
			set len [string length [help_plain [lindex $row $i]]]
			if {$i >= [llength $w]} { lappend w $len } \
			elseif {$len > [lindex $w $i]} { lset w $i $len }
		}
	}
	set first 1
	foreach row $rows {
		for {set i 0} {$i < [llength $row]} {incr i} {
			set cell [lindex $row $i]
			help_spans $t $cell [expr {$first ? {table mstrong} : {table}}] 1
			set pad [expr {[lindex $w $i] - [string length [help_plain $cell]]}]
			if {$i < [llength $row] - 1} {
				$t insert end "[string repeat { } $pad]  │ " table
			}
		}
		$t insert end "\n" table
		if {$first} {                        ;# a rule under the header, in the same pitch
			set segs {}
			foreach cw $w { lappend segs [string repeat ─ [expr {$cw + 2}]] }
			$t insert end "[join $segs ┼]\n" table
			set first 0
		}
	}
}

# --- following a link ------------------------------------------------------------------

proc help_link_binds {t} {
	$t tag bind link <Button-1> [list help_link_click $t %x %y]
	$t tag bind link <Enter> [list $t configure -cursor hand2]
	$t tag bind link <Leave> [list $t configure -cursor arrow]
}

# Which link was clicked: the L<n> tag under the pointer names it.
proc help_link_click {t x y} {
	foreach tag [$t tag names [$t index @$x,$y]] {
		if {[info exists ::help_link($t,$tag)]} { help_goto $::help_link($t,$tag) ; return }
	}
}

# Follow one link target: `topic.md`, `topic.md#heading`, or a bare `#heading` in this page.
proc help_goto {target} {
	set file $target ; set anchor ""
	regexp {^([^#]*)#(.*)$} $target -> file anchor
	if {$file eq ""} { set file $::help_topic }
	help_show $file $anchor
}

# Scroll a heading to the top of the page. A slug rio cannot place is left alone rather than
# guessed at — the reader is on the right page, just not moved.
proc help_anchor_see {slug} {
	set t .help.page.text
	if {![info exists ::help_anchor($t,$slug)]} { return 0 }
	$t yview $::help_anchor($t,$slug)
	return 1
}

# --- where the reader has been -----------------------------------------------------------

set ::help_back {} ; set ::help_fwd {} ; set ::help_anchor_now ""

proc help_history {dir} {
	if {![winfo exists .help]} return
	set from [list $::help_topic $::help_anchor_now]
	if {$dir eq "back"} {
		if {![llength $::help_back]} return
		set to [lindex $::help_back end]
		set ::help_back [lrange $::help_back 0 end-1]
		lappend ::help_fwd $from
	} else {
		if {![llength $::help_fwd]} return
		set to [lindex $::help_fwd end]
		set ::help_fwd [lrange $::help_fwd 0 end-1]
		lappend ::help_back $from
	}
	help_show [lindex $to 0] [lindex $to 1] 0
}

proc help_history_buttons {} {
	if {![winfo exists .help]} return
	.help.foot.back configure -state [expr {[llength $::help_back] ? "normal" : "disabled"}]
	.help.foot.fwd  configure -state [expr {[llength $::help_fwd]  ? "normal" : "disabled"}]
}

# --- showing a topic ---------------------------------------------------------------------

# Resolve a manual filename to a path on disk, refusing to leave the tree rio ships. The
# manual's links are relative by rule (D91); the ones that leave docs/ (`../README.md`)
# point at rio's OTHER documents, which are rio's own files too, so they are followed —
# but nothing outside the rio directory is, whatever a page asks for.
proc help_path {file} {
	if {$file eq "" || [file pathtype $file] ne "relative"} { return "" }
	set root [file dirname [help_dir]]
	set path [file normalize [file join [help_dir] $file]]
	if {$path ne $root && [string first "$root/" $path] != 0} { return "" }
	return $path
}

# How the footer names a file: its path relative to the rio directory, so a reader can go
# find it — `docs/git.md`, or `README.md` for the documents beside it.
proc help_label {file} {
	set path [help_path $file]
	if {$path eq ""} { return $file }
	set root [file dirname [help_dir]]/
	if {[string first $root $path] == 0} { return [string range $path [string length $root] end] }
	return $path
}

# Show one topic, optionally scrolled to one of its headings, and put the contents selection
# on it so the two halves never disagree — including when the topic was reached any way
# other than clicking its row. `push` is what separates a new destination from retracing
# one: Back and Forward re-show a page without recording the move as another move.
#
# A file that cannot be read is reported IN the window: a partial install should say what is
# missing, not break the one window that would explain it.
proc help_show {file {anchor ""} {push 1}} {
	set t .help.page.text
	if {$push && $::help_topic ne "" && [list $file $anchor] ne [list $::help_topic $::help_anchor_now]} {
		lappend ::help_back [list $::help_topic $::help_anchor_now]
		set ::help_fwd {}
	}
	set path [help_path $file]
	if {$path eq ""} {
		set text "## This is not a page of rio's manual\n\n`$file` is outside the rio\ndirectory, so the help viewer will not open it."
	} elseif {[catch {help_slurp $path} text]} {
		set text "## This topic could not be read\n\n`$path`\n\n$text"
	}
	$t configure -state normal
	$t delete 1.0 end
	help_paint $t [help_blocks $text]
	help_mark_hits $t $::help_needle
	$t configure -state disabled
	$t yview moveto 0
	.help.foot.where configure -text [help_label $file]
	set ::help_topic $file
	set ::help_anchor_now $anchor
	if {$anchor ne ""} { help_anchor_see $anchor }
	help_history_buttons
	# Which row is this page? A search result names a file AND a heading, so the exact pair
	# wins where it exists — otherwise the reader clicks one section and the list marks that
	# topic's first. A contents row is the file alone, which the loose match covers.
	set b .help.nav.list
	set row -1 ; set loose -1
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set p [rl_payload $b $i]
		if {$p eq [list $file $anchor]} { set row $i ; break }
		if {$loose < 0 && [lindex $p 0] eq $file} { set loose $i }
	}
	if {$row < 0} { set row $loose }
	# A document outside the contents (README.md, reached from index.md's own table) has no
	# row — so nothing is current, rather than the last topic still looking current.
	if {$row >= 0} { rl_select $b $row 0 } else { rl_clear $b }
}

# A font size N points bigger than `base`, honouring Tk's sign convention: a negative size
# is pixels, and "bigger" there means further from zero.
proc help_font_size {base delta} {
	return [expr {$base < 0 ? $base - $delta : $base + $delta}]
}

# Colours and fonts: at open, and again from apply_theme while the window is up — help can
# stay open across a theme change, unlike the modal dialogs that read the palette once. The
# list is a rich-list well like the file/git panes; the page is rendered prose, so it reads
# in the UI font with the editor's fixed-pitch font for the things that must not reflow.
#
# The render tags are configured HERE rather than at paint time for two reasons: a theme
# switch then recolours a page already on screen, and tag priority falls out of the order
# below (see the note at the end, where the headings are raised back over it).
proc help_restyle {} {
	if {![winfo exists .help]} return
	set c $::theme_colors
	set bg [dict get $c editor.bg]
	set fg [dict get $c editor.fg]
	set mute [blend_hex $fg $bg 45]
	.help configure -background [dict get $c ui.bg]
	.help.find configure -background [dict get $c ui.bg]
	.help.find.l configure -background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.help.find.e configure -background $bg -foreground $fg \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	.help.foot configure -background [dict get $c ui.bg]
	.help.foot.where configure -background [dict get $c ui.bg] \
		-foreground [blend_hex [dict get $c ui.fg] [dict get $c ui.bg] 45]
	foreach b {.help.foot.back .help.foot.fwd .help.foot.close} { $b configure -font RioUIFont }
	foreach f {.help.nav .help.page} { $f configure -background $bg }
	set b .help.nav.list
	$b configure -font RioUIFont -background $bg -foreground [dict get $c ui.fg]
	$b tag configure selrow   -background [dict get $c editor.selection]
	$b tag configure hoverrow -background [blend_hex $bg [dict get $c editor.selection] 25]
	$b tag configure helpsect -foreground [blend_hex [dict get $c ui.fg] $bg 35]
	$b tag raise selrow

	help_style .help.page.text

	# Search hits, last and raised: this one has to win -background over the block that
	# happens to be under it (a match inside a code block or a table is still a match). The
	# find bar's own role, falling back the way it does when a theme omits it. Help-only —
	# the plan view has nothing to search.
	set t .help.page.text
	$t tag configure hit -background [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag raise hit
}

# Dress a text widget to be painted by help_paint: every tag the renderer uses, from the
# current theme and UI font. Separate from help_restyle because the renderer has a second
# consumer — the plan view (D101) — and a plan should read exactly like a manual page; the
# window's own chrome is what stays in help_restyle.
proc help_style {t} {
	set c $::theme_colors
	set bg [dict get $c editor.bg]
	set fg [dict get $c editor.fg]
	set mute [blend_hex $fg $bg 45]
	set fam  [font configure RioUIFont -family]
	set sz   [font configure RioUIFont -size]
	set mfam [font configure RioEditorFont -family]
	$t configure -font [list $fam $sz] -background $bg -foreground $fg

	# Blocks.
	$t tag configure para  -spacing3 [expr {$sz > 0 ? $sz : 8}]
	$t tag configure h1 -font [list $fam [help_font_size $sz 6] bold] -spacing1 14 -spacing3 8
	$t tag configure h2 -font [list $fam [help_font_size $sz 3] bold] -spacing1 14 -spacing3 6
	$t tag configure h3 -font [list $fam [help_font_size $sz 1] bold] -spacing1 12 -spacing3 4
	for {set d 0} {$d <= 3} {incr d} {
		set ind [expr {18 + $d * 20}]
		$t tag configure li$d -lmargin1 $ind -lmargin2 [expr {$ind + 14}] -spacing3 4
	}
	$t tag configure listmark -foreground $mute
	$t tag configure quote -lmargin1 20 -lmargin2 20 -foreground $mute \
		-font [list $fam $sz italic] -spacing3 [expr {$sz > 0 ? $sz : 8}]
	$t tag configure code -font [list $mfam $sz] -wrap none -lmargin1 20 -lmargin2 20 \
		-background [blend_hex $bg $fg 8] -spacing1 4 -spacing3 8
	$t tag configure table -font [list $mfam $sz] -wrap none -lmargin1 12
	$t tag configure rule -foreground $mute -spacing1 6 -spacing3 6

	# Inline, after the blocks so these win the font.
	$t tag configure em         -font [list $fam $sz italic]
	$t tag configure strong     -font [list $fam $sz bold]
	$t tag configure strongem   -font [list $fam $sz bold italic]
	$t tag configure mem        -font [list $mfam $sz italic]
	$t tag configure mstrong    -font [list $mfam $sz bold]
	$t tag configure mstrongem  -font [list $mfam $sz bold italic]
	$t tag configure tt         -font [list $mfam $sz] -foreground [blend_hex $fg [dict get $c accent] 35]
	$t tag configure link -foreground [dict get $c accent] -underline 1
	# Tag priority is per-option and follows configure order, so the inline tags above beat
	# the block tags on -font — which is right inside a paragraph and wrong inside a heading,
	# where the heading's size has to win. Raising the headings settles only -font; a link in
	# one keeps its colour, since no heading sets a foreground.
	foreach h {h1 h2 h3} { $t tag raise $h }
}

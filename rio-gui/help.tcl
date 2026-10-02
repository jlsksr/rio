# rio-gui/help.tcl — the help viewer: contents, search, the Markdown renderer.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The help viewer: Help ▸ Contents…, F1 (D99, D100).
#
#   ┌ Find: [      ] ───────────────────────────┐
#   │ contents, or   │ the topic, rendered       │
#   │ search results │                           │
#   └ ◀ ▶  docs/git.md ──────────────── Close ──┘
#
# - The manual is `docs/`: one Markdown file per topic, the filename is the
#   topic id (D91), and index.md is the contents.
# - Rendered: headings, tables, code, links with Back and Forward.
# - The GUI reads the files itself, from its own tree, not through the core:
#   a remote core's docs/ would be another rio's manual (D29).
# ---------------------------------------------------------------------------

# The manual's directory, beside the code.
proc help_dir {} { return [file normalize [file join $::rio_dir .. docs]] }

# Read one manual file as UTF-8, whatever the system encoding (D21).
proc help_slurp {path} {
	set f [open $path r] ; fconfigure $f -encoding utf-8
	set t [read $f] ; close $f
	return $t
}

# The contents, from index.md, as {section title file} in document order.
# Under `## Contents`:
#   ### Section
#   - [Title](topic.md)
# docs.tcl holds index.md to this shape. A link out of docs/ is not a topic.
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

# Open the viewer, or raise it, and show `topic`, a docs/ filename. Not
# modal; one instance.
proc help_window {{topic ""}} {
	set w .help
	if {[winfo exists $w]} {
		raise $w ; focus $w.nav.list
		if {$topic ne ""} { help_show $topic }
		return
	}
	toplevel $w
	wm title $w "rio Help"

	# Find: an entry that turns the list below into search results as you type.
	frame $w.find
	label $w.find.l -text "Find:" -font RioUIFont
	entry $w.find.e -font RioUIFont -width 18
	ctx_bind_input $w.find.e   ;# (D115)
	pack $w.find.l -side left -padx {0 4}
	pack $w.find.e -side left
	bind $w.find.e <KeyRelease> help_find_changed
	# Escape clears the search; a second Escape closes the window.
	bind $w.find.e <Escape> {
		if {[.help.find.e get] ne ""} { .help.find.e delete 0 end ; help_find_changed ; break }
	}

	# Contents: a rich list (D42), like the file and git panes. A section
	# heading is a row too, not selectable: rl_* indexes rows by line.
	frame $w.nav -borderwidth 2 -relief sunken
	text $w.nav.list -width 24 -height 26 -wrap none -state disabled -cursor arrow \
		-insertwidth 0 -takefocus 1 -borderwidth 0 -highlightthickness 0 -padx 2 -pady 2
	pack $w.nav.list -side left -fill both -expand 1
	rl_init $w.nav.list help_pick {} {}

	# The topic, rendered (D100). Prose wraps to the window; code and tables
	# do not, hence the horizontal bar, which hides when unused.
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

	# Back and Forward, for links.
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

# Paint the contents list. index.md comes first, as "The rio manual".
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

# A row was selected: show it. The payload is a filename (contents) or
# {file slug} (a search result).
proc help_pick {payload} {
	lassign $payload file anchor
	if {$file ne ""} { help_show $file $anchor }
}

# ---------------------------------------------------------------------------
# Searching the manual, in the GUI, over the files the viewer reads. The
# manual is small, so a search reads every file again: no index. Line by
# line, because a result names the heading its match is under.
# ---------------------------------------------------------------------------

set ::help_needle ""   ;# the live search, "" when the contents list is showing

# Every heading with a match, as {file title slug heading hits}, in document order.
proc help_search {needle} {
	set needle [string tolower [string trim $needle]]
	if {$needle eq ""} { return {} }
	set out {}
	# index.md first, as in the contents.
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
			# Match the line without its markup: "wrap lines" finds `**Wrap Lines**`.
			if {[string first $needle [string tolower [help_plain $line]]] >= 0} { incr hits }
		}
		if {$hits} { lappend out [list $file $title $slug $sect $hits] }
	}
	return $out
}

# The results, shaped like the contents: a topic's title as a heading row,
# under it its matching sections with their hit counts.
proc help_fill_results {needle} {
	set b .help.nav.list
	rl_begin $b
	set hits [help_search $needle]
	if {![llength $hits]} {
		# Never a blank pane.
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

# The Find entry changed: show contents or results, and repaint the topic's
# highlights. Unchanged text does nothing.
proc help_find_changed {} {
	if {![winfo exists .help]} return
	set needle [string trim [.help.find.e get]]
	if {$needle eq $::help_needle} return
	set ::help_needle $needle
	if {$needle eq ""} { help_fill_contents } else { help_fill_results $needle }
	if {$::help_topic ne ""} { help_show $::help_topic $::help_anchor_now 0 }
}

# Highlight every occurrence of the needle in the rendered page.
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
# The renderer (D100), in two halves:
#
#   Markdown ──help_blocks──► block list ──help_paint──► text widget
#
# help_blocks needs no widget, so it can be tested as a function. It reads
# what the manual uses: headings, paragraphs, lists, links, bold, italic,
# inline code, fenced code, simple tables, blockquotes. Anything else shows
# as the text it is.
# ---------------------------------------------------------------------------

# A heading's anchor, by GitHub's rule: lowercase, no punctuation, hyphens
# for spaces. "Where everything lives" -> where-everything-lives
proc help_slug {s} {
	set s [string tolower [help_plain $s]]
	regsub -all {[^a-z0-9 -]} $s "" s
	return [string map {" " -} [string trim $s]]
}

# Inline markup, as {text style target} runs. style: "" | strong | em |
# strongem | code | link; target is a link's destination.
#   "a **b** [c](d.md)" -> {{a } {} {}} {b strong {}} {{ } {} {}} {c link d.md}
proc help_inline {s} {
	set re {`[^`]+`|\*\*\*[^*]+\*\*\*|\*\*[^*]+\*\*|\*[^*]+\*|\[[^\]]*\]\([^)]*\)}
	set out {}
	while {[regexp -indices $re $s m]} {
		lassign $m a b
		if {$a > 0} { lappend out [list [string range $s 0 $a-1] "" ""] }
		set tok [string range $s $a $b]
		# String compares, not a glob: `*` is a wildcard there.
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

# The text without its markup, as a reader sees it.
proc help_plain {s} {
	set out ""
	foreach run [help_inline $s] { append out [lindex $run 0] }
	return $out
}

# Close the open block. The accumulator variables are passed by name.
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

# One page as a list of blocks:
#   {heading LEVEL text} {para text} {quote text} {item DEPTH MARKER text}
#   {code text} {table ROWS} {rule}
# A prose block is one string, its line breaks joined: the window wraps it.
# Code and tables keep their lines.
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
		# Anything else continues the open block.
		if {$kind eq ""} { set kind para }
		append text [expr {$text eq "" ? "" : " "}] [string trim $ln]
	}
	help_flush out text kind depth marker
	return $out
}

# Is this row a table's `| --- | --- |` rule? Such a row is dropped. Only if
# every cell is dashes.
proc help_table_sep {cells} {
	foreach c $cells { if {![regexp {^:?-+:?$} $c]} { return 0 } }
	return [llength $cells]
}

# Paint a string's inline runs. `mono` picks the fixed-pitch tags: a table's
# columns must stay aligned.
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

# Paint the blocks. Records each heading's position (::help_anchor) and each
# link's target (::help_link), keyed by widget: the plan view (D101) uses
# this renderer too.
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

# A table, padded into columns. Widths are those of the visible text.
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

# Scroll a heading to the top. Returns 0 for an unknown slug.
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

# A manual filename as a path, or "" if it leaves the rio directory. A link
# out of docs/ (`../README.md`) is followed; nothing outside rio's tree is.
proc help_path {file} {
	if {$file eq "" || [file pathtype $file] ne "relative"} { return "" }
	set root [file dirname [help_dir]]
	set path [file normalize [file join [help_dir] $file]]
	if {$path ne $root && [string first "$root/" $path] != 0} { return "" }
	return $path
}

# The footer's name for a file: its path relative to the rio directory.
proc help_label {file} {
	set path [help_path $file]
	if {$path eq ""} { return $file }
	set root [file dirname [help_dir]]/
	if {[string first $root $path] == 0} { return [string range $path [string length $root] end] }
	return $path
}

# Show a topic, at `anchor` if given, and select its row in the list.
# `push` 0: do not record the move (Back and Forward). A file that cannot be
# read is reported in the page itself.
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
	# Which row is this page? An exact {file anchor} match (a search result)
	# wins over the first row of that file.
	set b .help.nav.list
	set row -1 ; set loose -1
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		set p [rl_payload $b $i]
		if {$p eq [list $file $anchor]} { set row $i ; break }
		if {$loose < 0 && [lindex $p 0] eq $file} { set loose $i }
	}
	if {$row < 0} { set row $loose }
	# A document outside the contents has no row: clear the selection.
	if {$row >= 0} { rl_select $b $row 0 } else { rl_clear $b }
}

# A font size `delta` bigger than `base`. A negative Tk size is pixels, and
# bigger means further from zero.
proc help_font_size {base delta} {
	return [expr {$base < 0 ? $base - $delta : $base + $delta}]
}

# Colours and fonts: at open, and from apply_theme while the window is up.
# The tags are configured here, not at paint time, so a theme change
# recolours the page on screen.
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

	# Search hits, raised over every block's background. The find bar's role.
	set t .help.page.text
	$t tag configure hit -background [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag raise hit
}

# Configure every tag help_paint uses on widget `t`, from the theme and the
# UI font. Its own proc: the plan view (D101) uses the renderer too.
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
	# Inline tags beat block tags on -font, which is wrong in a heading: its
	# size must win. So the headings are raised.
	foreach h {h1 h2 h3} { $t tag raise $h }
}

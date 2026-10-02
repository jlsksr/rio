# rio-gui/find.tcl — the find bar and the Search panel.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Find and Replace (D36). The core matches (buffer.find, buffer.matches); the
# bar holds the needle, the options and the caret (D22). Replace is a
# buffer.replace of the found range; Replace All is one op and one undo step.
# The bar acts on the focused group. Matches carry the `findmatch` tag; the
# current match is the selection.
# ---------------------------------------------------------------------------
set ::find_shown   0  ;# find bar visible? (Ctrl+F / Ctrl+H; Esc hides it)
set ::find_case    0  ;# Match case checkbox (off = fold case, the familiar default)
set ::find_word    0  ;# Whole word checkbox (off = substring; on = word-bounded, D51)
set ::find_regex   0  ;# Regex checkbox (on = needle is a Tcl-ARE pattern, D52 Phase C)
set ::find_starts  {} ;# match starts from the last find_update ("i of n" lookup)
set ::find_pending 0  ;# a coalesced find_update is queued (see apply_change)

# Show the bar, with or without the Replace row (Ctrl+F, Ctrl+H). A
# selection on one line becomes the needle. The entry gets the focus.
proc find_open {withReplace} {
	set ::find_shown 1
	pack .find -after .status -side bottom -fill x
	if {$withReplace} {
		grid .find.rl ; grid .find.re ; grid .find.rep ; grid .find.repall
	} else {
		grid remove .find.rl .find.re .find.rep .find.repall
	}
	set t [gw $::focus]
	if {![catch {$t get sel.first sel.last} s] && $s ne "" \
			&& [string first "\n" $s] < 0} {
		.find.e delete 0 end
		.find.e insert 0 $s
	}
	focus .find.e
	.find.e selection range 0 end
	.find.e icursor end
	find_update
}

# Hide the bar, clear the match paint everywhere, and hand focus back.
proc find_close {} {
	if {!$::find_shown} return
	set ::find_shown 0
	pack forget .find
	foreach g $::groups { [gw $g] tag remove findmatch 1.0 end }
	set ::find_starts {}
	focus [gget $::focus path]
}

# The count/status label at the bar's right ("12 matches", "3 of 12", …).
proc find_status {msg} { .find.count configure -text $msg }

# Recompute the matches in the focused buffer: paint them and show the
# count. On every keystroke in the needle, an option toggle, a tab switch and
# a buffer change. At most 1000 matches are painted; the count is exact.
proc find_update {} {
	set ::find_pending 0
	if {!$::find_shown} return
	set g $::focus ; set t [gw $g]
	$t tag remove findmatch 1.0 end
	set ::find_starts {}
	set needle [.find.e get]
	if {$needle eq ""} { find_status "" ; return }
	set resp [rio_call buffer.matches [dict create buffer [gcur $g] \
		needle $needle nocase [expr {!$::find_case}] wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} { find_status "" ; return }
	set n [dict get $resp result count]
	set painted 0
	foreach m [dict get $resp result matches] {
		lappend ::find_starts [dict get $m start]
		if {[incr painted] <= 1000} {
			$t tag add findmatch [dict get $m start] [dict get $m end]
		}
	}
	find_status [expr {$n == 0 ? "No matches" : "$n match[expr {$n==1 ? "" : "es"}]"}]
}

# Go to the next or previous match, from the selection's edge or the caret:
# select it and scroll to it. The search wraps; the label says so.
proc find_step {backwards} {
	if {!$::find_shown} { find_open 0 ; return }
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {$backwards} {
		if {[catch {$t index sel.first} from]} { set from [$t index insert] }
	} else {
		if {[catch {$t index sel.last} from]} { set from [$t index insert] }
	}
	set resp [rio_call buffer.find [dict create buffer [gcur $g] needle $needle \
		from $from nocase [expr {!$::find_case}] backwards $backwards \
		wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} return
	set r [dict get $resp result]
	if {![dict get $r found]} { find_status "No matches" ; return }
	set s [dict get $r start] ; set e [dict get $r end]
	$t tag remove sel 1.0 end
	$t tag add sel $s $e
	# No expr on an index: 1.10 would become the float 1.1.
	if {$backwards} { $t mark set insert $s } else { $t mark set insert $e }
	$t see $s
	set i [lsearch -exact $::find_starts $s]
	set n [llength $::find_starts]
	if {$i >= 0} {
		set msg "[expr {$i + 1}] of $n"
		if {[dict get $r wrapped]} { append msg " · wrapped" }
		find_status $msg
	}
}
proc find_next {} { find_step 0 }
proc find_prev {} { find_step 1 }

# Regex replaces whole-word: grey that box while Regex is on, search again.
proc find_regex_changed {} {
	.find.word configure -state [expr {$::find_regex ? "disabled" : "normal"}]
	find_update
}

# Replace the current match and go to the next. If the selection is not a
# match, this click only selects the next match: a replace is seen before
# it happens.
proc find_replace_one {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {![catch {list [$t index sel.first] [$t index sel.last]} range]} {
		lassign $range s e
		set cur [$t get $s $e]
		# Is the selection a match? Literal: equality. Regex: the whole
		# selection matches, and the replacement is its regsub, so
		# backreferences work.
		set newtext [.find.re get]
		if {$::find_regex} {
			set flags {} ; if {!$::find_case} { lappend flags -nocase }
			set same [expr {![catch {regexp {*}$flags -- "^(?:$needle)\$" $cur} m] && $m}]
			if {$same} { catch {regsub {*}$flags -- $needle $cur [.find.re get] newtext} }
		} else {
			set same [expr {$::find_case ? [string equal $cur $needle] \
			                             : [string equal -nocase $cur $needle]}]
		}
		if {$same} {
			if {[dict get [rio_call buffer.replace [dict create buffer [gcur $g] \
				start $s end $e text $newtext]] ok]} { mark_modified 1 }
		}
	}
	find_step 0
}

# Replace every match in one op (buffer.replace_all): one undo step. The
# buffer.changed event repaints the widget; only the caret is restored here.
proc find_replace_all {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	set at [$t index insert]
	set resp [rio_call buffer.replace_all [dict create buffer [gcur $g] \
		needle $needle text [.find.re get] nocase [expr {!$::find_case}] \
		wholeword $::find_word regex $::find_regex]]
	if {![dict get $resp ok]} return
	set n [dict get $resp result count]
	if {$n > 0} { mark_modified 1 }
	catch { $t mark set insert $at ; $t see insert }
	find_update
	find_status "Replaced $n"
}

# ---------------------------------------------------------------------------
# The Search panel (D52): search in one of three scopes; the results are a
# list grouped by file.
#   Project      project.search   the files on disk
#   Open docs    buffers.search   every open buffer's live text
#   Current doc  buffers.search, `only` the focused buffer
# Its widgets are under `.results`.
# ---------------------------------------------------------------------------
set ::search_shown   0        ;# panel visible?
set ::search_case    0        ;# "Match case" (off = case-insensitive, the friendlier first search)
set ::search_word    0        ;# "Whole word" (off = substring; on = word-bounded, D51)
set ::search_scope   "Current doc" ;# default; one of: Project | Open docs | Current doc
set ::search_replace 0        ;# the replace row shown? (Ctrl+H, like the find bar)

# Show the panel. `seed` is the query text; the default __sel__ takes it from
# the editor's selection. Searches at once if there is a needle. Project
# scope needs an open folder.
proc search_open {{seed __sel__}} {
	set root ""
	catch { set root [dict get [rio_result project.get {}] root] }
	rio::layout::unhide bottom search ; rio::layout::put bottom active search ;# give Search a tab
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	if {$seed eq "__sel__"} {
		catch {
			set sel [[gw $::focus] get sel.first sel.last]
			if {$sel ne "" && [string first "\n" $sel] < 0} {
				.results.hdr.e delete 0 end ; .results.hdr.e insert 0 $sel
			}
		}
	} else {
		.results.hdr.e delete 0 end ; .results.hdr.e insert 0 $seed
	}
	focus .results.hdr.e
	.results.hdr.e selection range 0 end
	.results.hdr.e icursor end
	if {$::search_scope eq "Project" && $root eq ""} {
		search_paint {} ; .results.hdr.count configure -text "open a folder to search"
		return
	}
	if {[string trim [.results.hdr.e get]] ne ""} search_run
}

# Hide the panel and hand focus back to the editor.
proc search_close {} {
	if {![rio::layout::shown search]} return
	rio::layout::hide bottom search
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	focus [gget $::focus path]
}

# Run the query for the scope and repaint the list. On Enter and on a
# toggle, not on every keystroke: a search walks a tree or every buffer.
proc search_run {} {
	if {!$::search_shown} return
	set needle [.results.hdr.e get]
	if {[string trim $needle] eq ""} { search_paint {} ; .results.hdr.count configure -text "" ; return }
	set nocase [expr {!$::search_case}]
	set rx $::search_regex
	switch -- $::search_scope {
		"Open docs" {
			set resp [rio_call buffers.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx]]
		}
		"Current doc" {
			set only ""
			catch { set only [gcur $::focus] }
			set resp [rio_call buffers.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx only $only]]
		}
		default {
			set resp [rio_call project.search [dict create needle $needle \
				nocase $nocase wholeword $::search_word regex $rx]]
		}
	}
	if {![dict get $resp ok]} {
		search_paint {} ; .results.hdr.count configure -text [dict get $resp error message]
		return
	}
	set r [dict get $resp result]
	search_paint [dict get $r results]
	set n [dict get $r count] ; set f [dict get $r files]
	if {$n == 0} {
		set msg "No results"
	} else {
		# The container noun follows the scope: on-disk files vs open buffers.
		set unit [expr {$::search_scope eq "Project" ? "file" : "buffer"}]
		set msg "$n [expr {$n == 1 ? {match} : {matches}}] · $f $unit[expr {$f == 1 ? {} : {s}}]"
		if {[dict get $r truncated]} { append msg " (truncated)" }
	}
	.results.hdr.count configure -text $msg
}

# Repaint the list: per file a header row, then one row per matching line.
#
#   src/main.tcl
#      12  set x [foo $y]
#      40  foo bar
#
# A file object has `rel` (a disk file) or `name` (a buffer); a row's payload
# has `path` or `buffer`, so one painter serves every scope. Each hit is
# tagged `fimatch`, from the core's `cols` and `lens`, shifted by the prefix.
proc search_paint {results} {
	set b .results.well.body
	rl_begin $b
	set L 0
	set isbuf 0
	foreach fdict $results {
		set isbuf [dict exists $fdict buffer]
		set head [expr {$isbuf ? [dict get $fdict name] : [dict get $fdict rel]}]
		$b insert end "$head\n" fifile
		rl_row $b 0 ""
		incr L
		foreach m [dict get $fdict matches] {
			set prefix [format "  %5d  " [dict get $m line]]
			set txt [string trimright [dict get $m text]]
			$b insert end "$prefix$txt\n"
			set loc [dict create line [dict get $m line] col [dict get $m col]]
			if {$isbuf} {
				dict set loc buffer [dict get $fdict buffer]
			} else {
				dict set loc path [dict get $fdict path]
			}
			rl_row $b 1 $loc
			incr L
			set plen [string length $prefix]
			set tend [expr {$plen + [string length $txt]}]
			foreach c [dict get $m cols] len [dict get $m lens] {
				set s [expr {$plen + $c - 1}]
				if {$s >= $tend || $len <= 0} continue   ;# past the trimmed/capped text, or zero-width
				set e [expr {min($s + $len, $tend)}]
				$b tag add fimatch $L.$s $L.$e
			}
		}
	}
	rl_end $b
}

# Go to a result: open the file or switch to the buffer, and put the caret
# on the match. The index is built as a string, never through expr.
proc search_activate {payload} {
	if {[dict exists $payload buffer]} {
		set id [dict get $payload buffer]
		if {![dict exists $::buffers $id]} return   ;# a buffer the GUI no longer tracks
		activate $id
	} else {
		if {![do_open [dict get $payload path]]} return
	}
	set t [gw $::focus]              ;# widget COMMAND for the subcommands below…
	catch {
		$t mark set insert "[dict get $payload line].[expr {[dict get $payload col] - 1}]"
		$t see insert
	}
	curline_update $::focus          ;# the jump landed after activate's refresh_status
	focus [gget $::focus path]       ;# …but focus takes the window PATH (the gutter-bug trap)
}

# From the find bar to the Search panel (Ctrl+Shift+F in the bar): the
# needle, the options and the replacement come along; the scope is Project.
proc search_from_bar {} {
	set ::search_case  $::find_case
	set ::search_word  $::find_word
	set ::search_regex $::find_regex
	set ::search_scope "Project"
	search_regex_sync
	if {[llength [grid info .find.rep]] > 0} {
		.results.rep.e delete 0 end ; .results.rep.e insert 0 [.find.re get]
		search_show_replace 1
	}
	search_open [.find.e get]
}

# Regex replaces whole-word here too: grey that box while Regex is on.
proc search_regex_sync {} {
	.results.hdr.word configure -state [expr {$::search_regex ? "disabled" : "normal"}]
}
proc search_regex_changed {} { search_regex_sync ; search_run }

# Show or hide the replace row (D52), just above the query row.
proc search_show_replace {on} {
	set ::search_replace $on
	if {$on} {
		pack .results.rep -side bottom -fill x
		focus .results.rep.e
	} else {
		pack forget .results.rep
	}
}

# Replace every match in the scope (D52).
#   buffer scopes   buffer.replace_all: one undo step per buffer, unsaved
#   Project         project.replace, after a confirmation: open files in
#                   their buffers, closed files on disk
# Afterwards the list is cleared and the count line says what changed.
proc search_replace_all {} {
	if {!$::search_shown} return
	set needle [.results.hdr.e get]
	if {[string trim $needle] eq ""} { focus .results.hdr.e ; return }
	set repl   [.results.rep.e get]
	set nocase [expr {!$::search_case}]
	set ww     $::search_word
	set rx     $::search_regex
	switch -- $::search_scope {
		"Current doc" {
			set resp [rio_call buffer.replace_all [dict create buffer [gcur $::focus] \
				needle $needle text $repl nocase $nocase wholeword $ww regex $rx]]
			set n [expr {[dict get $resp ok] ? [dict get $resp result count] : 0}]
			if {$n > 0} { mark_modified 1 }
			set msg "Replaced $n"
		}
		"Open docs" {
			set n 0 ; set touched 0
			foreach id [dict keys $::buffers] {
				set resp [rio_call buffer.replace_all [dict create buffer $id \
					needle $needle text $repl nocase $nocase wholeword $ww regex $rx]]
				if {[dict get $resp ok] && [dict get $resp result count] > 0} {
					incr n [dict get $resp result count] ; incr touched
					bufset $id modified 1
				}
			}
			if {$touched > 0} refresh_all
			set msg "Replaced $n · $touched buffer[expr {$touched == 1 ? {} : {s}}]"
		}
		default {
			# Project: destructive on disk for closed files — count, then confirm.
			set sresp [rio_call project.search [dict create needle $needle \
				nocase $nocase wholeword $ww regex $rx]]
			set cnt [expr {[dict get $sresp ok] ? [dict get $sresp result count] : 0}]
			if {$cnt == 0} { search_paint {} ; .results.hdr.count configure -text "No results" ; return }
			set ans [tk_messageBox -icon warning -type yesno -title "Replace in Project" \
				-message "Replace all $cnt occurrence[expr {$cnt == 1 ? {} : {s}}] of \"$needle\" across the project?\n\nOpen documents are edited in the editor (undoable); files not open are written to disk and cannot be undone."]
			if {$ans ne "yes"} return
			set resp [rio_call project.replace [dict create needle $needle text $repl \
				nocase $nocase wholeword $ww regex $rx]]
			if {![dict get $resp ok]} {
				.results.hdr.count configure -text [dict get $resp error message] ; return
			}
			set r [dict get $resp result]
			foreach id [dict get $r bufferids] {
				if {[dict exists $::buffers $id]} { bufset $id modified 1 }
			}
			if {[llength [dict get $r bufferids]] > 0} refresh_all
			set nb [llength [dict get $r bufferids]] ; set nf [dict get $r files]
			set msg "Replaced [dict get $r count] · $nf file[expr {$nf == 1 ? {} : {s}}], $nb buffer[expr {$nb == 1 ? {} : {s}}]"
		}
	}
	search_paint {}
	.results.hdr.count configure -text $msg
}

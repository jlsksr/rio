# rio-gui/find.tcl — the find bar and the Search panel.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Find / Replace (D36). The bar is a thin view: the MATCHING runs in
# the core (buffer.find / buffer.matches — the core owns the canonical text,
# D3), and the bar carries only the frontend-local state those ops are
# stateless about (D22): the needle, the options, and the caret it passes as
# `from`. Replace is the existing edit path — a found range plus a
# buffer.replace; Replace All is one op and ONE undo step. The bar always acts
# on the FOCUSED group; matches are painted with the `findmatch` tag
# (editor.findmatch role, D24), the current match with the native selection.
# ---------------------------------------------------------------------------
set ::find_shown   0  ;# find bar visible? (Ctrl+F / Ctrl+H; Esc hides it)
set ::find_case    0  ;# Match case checkbox (off = fold case, the familiar default)
set ::find_word    0  ;# Whole word checkbox (off = substring; on = word-bounded, D51)
set ::find_regex   0  ;# Regex checkbox (on = needle is a Tcl-ARE pattern, D52 Phase C)
set ::find_starts  {} ;# match starts from the last find_update ("i of n" lookup)
set ::find_pending 0  ;# a coalesced find_update is queued (see apply_change)

# Show the bar (packing it above the status bar), with or without the Replace
# row — Ctrl+F and Ctrl+H open the same bar in the two shapes. A single-line
# editor selection pre-fills the needle (the 90s convention); the needle entry
# gets focus with its text selected, so typing starts a fresh search.
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

# Recompute the matches for the focused group's buffer: repaint the findmatch
# tag and refresh the count. Runs on every needle keystroke, on the case
# toggle, on a tab switch, and (coalesced) after any buffer change — one
# buffer.matches round-trip, the same cost as one typed character. Painting is
# capped so a one-letter needle in a huge file cannot stall the view; the
# count stays exact.
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

# Jump to the next (or previous) match: ask the core for the match after the
# current one — after the selection's edge, else the caret — select it, put
# the caret on its far side, and scroll it into view. Search wraps around; the
# label says so.
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
	# No expr here: an index like 1.10 would coerce to the float 1.1 (see
	# editor_proxy's delete arm for the original bite of this).
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

# Regex supersedes whole-word (a pattern writes its own boundaries), so grey the
# Whole word box while Regex is on, then re-run the search with the new mode.
proc find_regex_changed {} {
	.find.word configure -state [expr {$::find_regex ? "disabled" : "normal"}]
	find_update
}

# Replace the current match, then jump to the next: if the selection IS a
# match of the needle, replace it through the ordinary edit op; otherwise this
# first click just selects the next match and the next click replaces it (the
# classic two-step, so a replace is always visible before it happens).
proc find_replace_one {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {![catch {list [$t index sel.first] [$t index sel.last]} range]} {
		lassign $range s e
		set cur [$t get $s $e]
		# Does the selection stand as a match? Literal: an exact (case-folded) equality.
		# Regex: the whole selection matches the pattern — and the replacement is the
		# regsub of the pattern over the selection, so backreferences resolve against
		# this actual match (a client-side substitution of an already-matched string).
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

# Replace every match in one op (buffer.replace_all): one round-trip, one undo
# step. The buffer.changed event repaints the widget before the reply lands
# (events precede replies on the channel), so only the caret needs restoring.
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
# The Search panel (D52): the grown-up sibling of the inline find bar —
# find across three SCOPES (Current doc / Open docs / Project) in one bottom tool
# window, its results a grouped, navigable list. Two core engines sit behind the
# scope selector, so buffer and project search can never disagree:
#   Project    → project.search  (the on-disk tree; only the core sees it remotely)
#   Open docs  → buffers.search  (every open buffer's LIVE text — unsaved edits too)
#   Current doc→ buffers.search with `only` the focused buffer
# It grew from the D51 find-in-files panel (the `.results` widget paths are kept),
# and is the concrete bottom-site tenant D35 will re-home into its dock. Replace
# (Phase B) and regex (Phase C) are later arcs; the query row leaves room. rl_*
# draws the grouped list; the inline find bar stays the quick in-buffer path (D35 #5).
# ---------------------------------------------------------------------------
set ::search_shown   0        ;# panel visible?
set ::search_case    0        ;# "Match case" (off = case-insensitive, the friendlier first search)
set ::search_word    0        ;# "Whole word" (off = substring; on = word-bounded, D51)
set ::search_scope   "Current doc" ;# default; one of: Project | Open docs | Current doc
set ::search_replace 0        ;# the replace row shown? (Ctrl+H, like the find bar)

# Show the panel (above the find bar / status). `seed` overrides the query text —
# the sentinel __sel__ (the default) seeds from the editor selection like the find
# bar; any other value is used verbatim (the bar handoff passes its needle). Search
# at once if there is a needle. Project scope needs an open folder; the buffer
# scopes search the open documents regardless, so only Project reports "no folder".
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

# Run the query for the current scope and repaint the grouped result list. Empty
# needle clears; the option toggles and the scope selector re-run (their -command).
# One round-trip per Enter/toggle — search walks a tree or every buffer, so it is
# not a per-keystroke live paint like the in-buffer find bar.
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

# Repaint the rich-list: a non-selectable file-header row then one selectable row
# per matching line ("<line>  <text>"), its payload the location to open. Mirrors
# the git/files panes' rl_* rendering. A file object carries EITHER `rel` (a disk
# path, from project.search) or `name` (an open buffer, from buffers.search) for
# the header, and its rows a `path` (open via do_open) or a `buffer` id (switch via
# activate) — so one render path serves every scope. Every occurrence on a row is
# tinted with the `fimatch` band (D51): the core hands back each hit's 1-based start
# column in `cols` and its char length in the parallel `lens` (so a variable-length
# regex hit sizes correctly, D52 Phase C), offset here by the "<line>  " prefix. `L`
# tracks the text-widget line as rows are appended (header rows count too).
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

# Activate a result row: go to its location and move the caret to the match. A disk
# hit (payload `path`) opens/switches via do_open; an open-buffer hit (payload
# `buffer`) switches to that tab via activate. The index is built as a string, not
# through expr, so a column like 10 isn't coerced to a float (the editor_proxy /
# buffer.find float trap, met again).
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

# Escalate from the inline find bar into the Search panel (Ctrl+Shift+F while the
# bar is focused): carry the bar's needle + options across and widen to Project
# scope (the point of escalating). If the bar was in Replace mode, carry the
# replacement text and open the panel's replace row too. The panel then owns the query.
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

# Regex supersedes whole-word in the panel too: grey the panel's Whole word box
# while Regex is on. `search_regex_changed` also re-runs the query (the checkbox's
# -command); `search_regex_sync` only reflects the state (used on a handoff).
proc search_regex_sync {} {
	.results.hdr.word configure -state [expr {$::search_regex ? "disabled" : "normal"}]
}
proc search_regex_changed {} { search_regex_sync ; search_run }

# Show or hide the replace row (D52 Phase B) — the find bar's Ctrl+H, brought to the
# panel. Packed -side bottom so it lands just ABOVE the bottom-anchored query row (a
# later -side bottom slave stacks above the earlier one), keeping the query field
# pinned to the bottom edge when the replace row appears/disappears.
proc search_show_replace {on} {
	set ::search_replace $on
	if {$on} {
		pack .results.rep -side bottom -fill x
		focus .results.rep.e
	} else {
		pack forget .results.rep
	}
}

# Replace every match for the current scope (D52 Phase B). Buffer scopes go through
# buffer.replace_all — one undo step per buffer, the change UNSAVED — with each
# touched buffer flagged modified. Project goes through the destructive, confirm-
# gated project.replace: open files are edited in their buffers (undoable), closed
# files rewritten on disk. The old hit locations are stale afterwards, so the list
# is cleared and the count line reports what changed (mirroring the find bar).
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

# rio-gui/highlight.tcl — syntax highlighting and editing modes.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Syntax highlighting (D32). Highlighting is PRESENTATION, so the GUI
# owns it: pure, swappable per-line scanner modules live in syntax/ (Tk-free — a
# future TUI reuses them), and the GUI is the *applier*. It maps each token TYPE
# onto the theme's syntax.* colour role as a text tag (apply_theme), and re-tokenises
# the active buffer after edits.
#
# Re-highlighting is INCREMENTAL. After an edit (hl_edit) only the changed line's state
# can differ, so hl_incremental re-scans from the first dirty line DOWNWARD and stops as
# soon as a line's freshly-computed entry state matches the cached one (past the edit) —
# the state has re-converged, so every line below is unchanged. Typing thus re-tags a
# handful of lines, not the whole file, while multi-line context (open comments, script
# bodies, quoted values that carry state across lines) stays correct. Edits are coalesced
# on the idle handler so a burst of keystrokes paints once.
#
# Highlighting is also VIEWPORT-SCOPED (D126). Painting the whole buffer on open cost
# ~1.35 seconds per megabyte and was 81% of the price of opening a large file — the
# reason D125 had to make an 8 MB file a question at all. Two pieces of state replace
# the whole-buffer pass, and the trick is that the first one is the OLD cache, weakened:
#
#   hl_enter      — the SCAN FRONTIER. Still the scan state entering each line, index
#                   i-1 for line i, still exact; it just stops at some line E <= the
#                   line count instead of covering the file. Below E nothing is claimed.
#   hl_lo, hl_hi  — the PAINTED INTERVAL: the lines that actually carry syn:* tags.
#                   0 0 means none. Always within the frontier (hl_hi <= E).
#
# Weakening "exact everywhere" to "exact up to E" is what makes this small: the splice
# in hl_edit, the convergence early-out in hl_incremental and the cache's indexing all
# work unchanged on a shorter list, and truncating the frontier is always a legal thing
# to do because the frontier never promises anything below itself. On a file that fits
# on screen the frontier IS the whole file and the painted interval IS every line, so
# small files run exactly the code they ran before.
#
# hl_ensure is the one entry point: it grows the frontier toward the visible window (in
# hl_chunk-sized pieces that yield to the event loop, so a jump to the end of a huge
# file streams colour in rather than freezing) and paints only what is newly exposed,
# never re-tagging a line that is already correct. Scrolling reaches it through
# edscroll, i.e. through Tk's -yscrollcommand, which is also how the wheel, the
# scrollbar, `see`, vi's jumps and find's step all arrive — one seam, not five.
#
# What stays whole-buffer on purpose: entry states are exact, never guessed from a
# bounded back-scan, so reaching line N still means having scanned the N-1 lines above
# it. That work is real but it is chunked, off the blocking path, and paid once.
# ---------------------------------------------------------------------------

# Load the tokeniser modules: the registry (the contract) then every language
# module. Shipped modules load first, then the user's own from
# $XDG_CONFIG_HOME/rio/syntax/, so a drop-in file re-registering an extension
# replaces the shipped highlighter (the same override idea as user themes, D24). A
# broken module is reported, not fatal — it must never stop the editor from starting.
proc hl_load {} {
	set base [file join $::rio_dir .. syntax]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: syntax registry failed to load: $err" ; return
	}
	foreach dir [list $base [hl_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: syntax module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in highlighter dir (beside the user themes dir, D21 locations).
proc hl_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio syntax]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio syntax]
	}
	return ""
}

# ---------------------------------------------------------------------------
# Editing modes (D38, D41): the core ships the Windows mode only; emacs
# and vi install as extensions into the user drop-in dir. Loaded exactly like the
# syntax highlighters — registry first, shipped modules, then user drop-ins that
# shadow by re-registering. The active mode lives on the shared RioMode bind tag,
# which make_editor_group slots between each text widget and Tk's Text class:
#
#     .eg<g>.t   RioMode   Text   .   all
#
# so the precedence is fixed by construction: app keymap chords (on the widget
# path, D23) always beat the mode; mode bindings that `break` beat Tk's Text
# defaults; mode bindings that don't fall through to them.
# ---------------------------------------------------------------------------
proc modes_load {} {
	set base [file join $::rio_dir .. modes]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: modes registry failed to load: $err" ; return
	}
	foreach dir [list $base [modes_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: mode module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in modes dir (a sibling of the syntax and themes dirs, D21).
proc modes_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio modes]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio modes]
	}
	return ""
}

# The one applier for ::edit_mode (the D31 pattern: menu radio and boot both land
# here). Detach the outgoing mode, wipe the tag centrally — a mode can never leak
# a binding — then attach the new one. A persisted mode that no longer exists
# falls back to the default rather than erroring at startup (same spirit as the
# theme fallback).
proc apply_editmode {} {
	if {[info commands rio::modes::exists] eq ""} return
	if {![rio::modes::exists $::edit_mode]} {
		if {![rio::modes::exists windows]} return
		set ::edit_mode windows
	}
	if {$::editmode_active ne ""} {
		catch { rio::modes::detach $::editmode_active RioMode }
	}
	catch { col_clear }   ;# column editing (D40) is windows-only; drop any live selection
	foreach seq [bind RioMode] { bind RioMode $seq "" }
	set ::editmode_status ""
	rio::modes::attach $::edit_mode RioMode
	set ::editmode_active $::edit_mode
	sync_column_edit_menu
	refresh_status
	prefs_save
}

# Column editing rearranges text in a way that only the windows mode's caret model
# makes sense of — vi and emacs carry their own block/rectangle notions — so the
# Settings toggle is greyed out (whatever its stored value) unless windows mode is
# active. apply_editmode calls this on every mode switch; boot calls it once.
proc sync_column_edit_menu {} {
	if {![winfo exists .m.settings]} return
	set state [expr {$::edit_mode eq "windows" ? "normal" : "disabled"}]
	catch { .m.settings entryconfigure "Column Editing*" -state $state }
}

# Fill the Settings ▸ Editing Mode cascade from the registry — one radio per
# registered mode, so a user drop-in shows up with no menu wiring of its own.
proc modes_menu_fill {} {
	if {![winfo exists .m.settings.editmode]} return
	.m.settings.editmode delete 0 end
	if {[info commands rio::modes::names] eq ""} return
	foreach name [rio::modes::names] {
		.m.settings.editmode add radiobutton -label [rio::modes::label $name] \
			-variable ::edit_mode -value $name -command apply_editmode
	}
}

# Pick the scanner for group `g`'s active buffer ("" = no highlighter, e.g. a scratch
# buffer or a plain-text file). Runs on open / switch. A language the user picked by
# hand (the buffer's `lang`, D112) wins; otherwise the file name decides. A picked
# language that is no longer registered (its extension removed) falls back to the file
# name rather than erroring. The scanner + language name live in the group's cache, one
# per editor widget (D33).
proc hl_select {g} {
	gset $g hl_scan "" ; gset $g hl_lang ""
	if {[info procs rio::syntax::for_path] eq ""} return
	set id [gcur $g]
	if {$id eq "" || ![dict exists $::buffers $id]} return
	set lang [expr {[dict exists $::buffers $id lang] ? [bufget $id lang] : ""}]
	if {$lang eq "plain"} return
	if {$lang ne "" && [rio::syntax::for_lang $lang] ne ""} {
		gset $g hl_scan [rio::syntax::for_lang $lang]
		gset $g hl_lang $lang
		return
	}
	set path [bufget $id path]
	if {$path ne ""} {
		gset $g hl_scan [rio::syntax::for_path $path]
		gset $g hl_lang [rio::syntax::lang_for_path $path]
	}
}

# Re-pick and repaint the highlighter in every group showing buffer `id` — after its
# path changed (Save As, a rename) or its language was picked by hand (D112).
proc hl_refresh_buffer {id} {
	foreach g $::groups {
		if {[gcur $g] eq $id} { hl_select $g ; hl_reset $g }
	}
}

# Set buffer `id`'s language by hand (D112): "" = detect by file name, "plain" = no
# highlighting, else a registered language name. View state only, like `modified`.
proc set_buffer_lang {id lang} {
	if {![dict exists $::buffers $id]} return
	bufset $id lang $lang
	hl_refresh_buffer $id
	refresh_status
}

# View ▸ Language… (D112): pick the current buffer's highlighter by hand, for pasted
# code in an untitled buffer or a file the name guesses wrong. The shared bounded picker,
# not a cascade — the list grows with every installed syntax extension (D92). Payloads
# are never "" because pick_dialog returns "" on Cancel.
proc language_pick_rows {} {
	set p [bufget $::cur path]
	set detected [expr {$p ne "" ? [rio::syntax::lang_for_path $p] : ""}]
	if {$detected eq ""} { set detected "plain text" }
	set rows [list [list auto "Auto-detect ($detected)"] [list plain "Plain Text"]]
	foreach name [rio::syntax::names] { lappend rows [list lang:$name $name] }
	return $rows
}
proc language_pick_dialog {} {
	if {$::cur eq "" || [info procs rio::syntax::names] eq ""} { bell ; return }
	set lang [bufget $::cur lang]
	set initial [expr {$lang eq "" ? "auto" : $lang eq "plain" ? "plain" : "lang:$lang"}]
	set pick [pick_dialog "Language" [language_pick_rows] $initial]
	switch -glob -- $pick {
		""      { return }
		auto    { set_buffer_lang $::cur "" }
		plain   { set_buffer_lang $::cur plain }
		lang:*  { set_buffer_lang $::cur [string range $pick 5 end] }
	}
}

# Widget `t`'s current line count (1-based; a Tk text widget always has at least line
# 1). A group's hl_enter is kept the same length, so index i-1 is line i's state.
proc hl_linecount {t} {
	return [lindex [split [$t index "end-1c"] .] 0]
}

# Re-tag one line L of widget `t` with scanner `scan`, from its already-known entry
# `state`/`param`: scan it, clear the old syntax tags on just that line, repaint, and
# return the state ENTERING line L+1. `clear` is 0 when the caller has already cleared
# a whole range in one go (hl_paint_range) — that per-line removal is 13 widget calls
# and most of the cost of painting, so a range pass hoists it out of the loop.
proc hl_paint_line {t scan L state param {clear 1}} {
	set line [$t get $L.0 "$L.0 lineend"]
	lassign [rio::syntax::scan_line $scan $line $state $param] spans state param
	if {$clear} {
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $L.0 "$L.0 lineend" }
	}
	foreach {c0 c1 type} $spans { $t tag add syn:$type $L.$c0 $L.$c1 }
	return [list $state $param]
}

# The lines group `g` wants highlighted: what is on screen, plus ::hl_margin above and
# below so an ordinary scroll usually finds its new lines already painted. Asks the
# WIDGET via @0,y rather than doing pixel arithmetic, exactly as gutter_redraw does —
# so a wrapped logical line occupying several display rows is counted once and -wrap
# word needs no special case. A group whose window has not been mapped yet reports a
# height of 1; fall back to its configured -height rather than a degenerate window.
proc hl_window {g nlines} {
	set t [gw $g]
	set h [winfo height [gget $g path]]
	set top [expr {int([$t index @0,0])}]
	if {$h < 2} {
		set bot [expr {$top + [$t cget -height]}]
	} else {
		set bot [expr {int([$t index @0,[expr {$h - 1}]])}]
	}
	set w0 [expr {$top - $::hl_margin}]
	set w1 [expr {$bot + $::hl_margin}]
	if {$w0 < 1} { set w0 1 }
	if {$w1 > $nlines} { set w1 $nlines }
	return [list $w0 $w1]
}

# The cached entry state for a line, as ONE object shared by every line that enters in
# the same state (see ::hl_states). hl_enter holds one entry per line and a 16 MB file is
# 500,000 of them, so a freshly allocated two-element list per line is most of what the
# frontier costs in memory — and it is the same two or three values over and over.
proc hl_state {state param} {
	set key [list $state $param]
	if {[dict exists $::hl_states $key]} { return [dict get $::hl_states $key] }
	if {[dict size $::hl_states] < $::hl_states_max} { dict set ::hl_states $key $key }
	return $key
}

# Grow group `g`'s scan frontier toward line `target`, at most ::hl_chunk lines per
# call. This SCANS without painting — roughly 23 us a line against 56 for a painted
# one — because all we need from the lines above the viewport is the state they hand
# down. If the target is still out of reach the pass re-arms itself; the continuation
# re-enters hl_ensure rather than this proc, so if the user scrolled somewhere else in
# the meantime the next chunk aims at the new window instead of the stale one.
#
# The chunk's text is pulled from the widget ONCE and split, rather than per line. Two Tk
# index parses and a B-tree descent cost 1.7 us a line where the bulk fetch costs 0.1, and
# this loop always walks its whole budget, so nothing is fetched that is not scanned.
# (hl_incremental below keeps its per-line `get` for the opposite reason: it usually
# re-converges within a line or two of the edit, so a chunk-sized fetch there would pull
# a thousand lines to read three.)
#
# Worth stating plainly, because it bounds what is left: at 20.2 us a line the SCANNER is
# 19.5 of them. The fetch was 8% and the entry-state allocation was inside the noise. No
# further work on this loop can matter much — the next lever, if one is ever wanted, is a
# per-line fast path inside the scanners themselves, and that is a change to D32's contract
# across 33 of them. Measured and written down, deliberately not built (ROADMAP).
proc hl_extend {g target nlines} {
	set t [gw $g] ; set scan [gget $g hl_scan]
	set enter [gget $g hl_enter]
	set E [llength $enter]
	if {$E == 0} {
		lassign [rio::syntax::start] state param
		lappend enter [hl_state $state $param]      ;# state entering line 1
		set E 1
	} else {
		lassign [lindex $enter end] state param
	}
	if {$target > $nlines} { set target $nlines }
	set stop [expr {$E + $::hl_chunk - 1}]          ;# last line this pass may scan
	if {$stop > $target - 1} { set stop [expr {$target - 1}] }
	if {$stop >= $E} {
		# `get` to a lineend keeps the newlines BETWEEN the lines and drops the one
		# after the last, so this splits into exactly the lines E..stop — including the
		# buffer's final line, which has no newline after it either way.
		foreach line [split [$t get $E.0 "$stop.0 lineend"] "\n"] {
			lassign [rio::syntax::scan_line $scan $line $state $param] _ state param
			lappend enter [hl_state $state $param]  ;# state entering line E+1
			incr E
		}
	}
	gset $g hl_enter $enter
	if {$E < $target} { hl_vmark $g 0 }
}

# Paint lines a..b of group `g` from the entry states already cached for them. One tag
# removal for the whole range instead of one per line; the caller guarantees a..b lies
# within the frontier (hl_paint_range clamps rather than trusting that blindly).
proc hl_paint_range {g a b} {
	set t [gw $g] ; set scan [gget $g hl_scan]
	set enter [gget $g hl_enter]
	if {$a < 1} { set a 1 }
	if {$b > [llength $enter]} { set b [llength $enter] }
	if {$b < $a} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $a.0 "$b.0 lineend" }
	lassign [lindex $enter [expr {$a - 1}]] state param
	for {set L $a} {$L <= $b} {incr L} {
		lassign [hl_paint_line $t $scan $L $state $param 0] state param
	}
}

# Make sure group `g`'s visible window is highlighted. Idempotent and cheap when there
# is nothing to do, which is the common case — it runs on every scroll.
proc hl_ensure {g} {
	gset $g hl_vpending 0
	if {![dict exists $::grp $g]} return
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	if {[gget $g hl_scan] eq ""} return
	# An edit is queued: its incremental pass owns the frontier and may truncate it, so
	# let that run first. Idle handlers fire in order, so re-arming on idle puts us
	# behind the hl_schedule that hl_edit already queued.
	if {[gget $g hl_pending] || [gget $g hl_dirty] > 0} { hl_vmark $g ; return }
	set t [gw $g]
	set nlines [hl_linecount $t]
	lassign [hl_window $g $nlines] w0 w1
	if {[llength [gget $g hl_enter]] < $w1} {
		hl_extend $g $w1 $nlines
		set E [llength [gget $g hl_enter]]
		if {$w1 > $E} { set w1 $E }   ;# paint only as far as we can vouch for
	}
	if {$w1 < $w0} return
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	if {$hi > $nlines} { set hi $nlines }
	if {$lo == 0 || $w1 < $lo - 1 || $w0 > $hi + 1} {
		# A jump: the new window is disjoint from what is painted. Everything painted
		# is off-screen by construction, so wiping it cannot flicker.
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
		hl_paint_range $g $w0 $w1
		gset $g hl_lo $w0 ; gset $g hl_hi $w1
		return
	}
	# An ordinary scroll: paint only the strip that just came into range, so a line
	# that is already correct is never re-tagged.
	if {$w0 < $lo} { hl_paint_range $g $w0 [expr {$lo - 1}] ; gset $g hl_lo $w0 }
	if {$w1 > $hi} { hl_paint_range $g [expr {$hi + 1}] $w1 ; gset $g hl_hi $w1 }
}

# Queue a coalesced hl_ensure on group `g`. `now` picks a timer over an idle handler,
# which is what the chunked frontier scan wants: a self-re-registering IDLE handler can
# be serviced again in the same event-loop pass and starve window events, while a timer
# is unambiguously behind them, so the UI stays live while a long prefix builds.
proc hl_vmark {g {now 0}} {
	if {[gget $g hl_vpending]} return
	gset $g hl_vpending 1
	if {$now} {
		after 0 [list hl_ensure $g]
	} else {
		after idle [list hl_ensure $g]
	}
}

# Drop group `g`'s highlight state and start again from the visible window: on open, on
# a tab switch, and whenever the scanner itself changes (Save As, View ▸ Language…, a
# reloaded syntax extension). Reads text from the widget, which already holds the
# canonical content — no core call.
#
# The first paint is SYNCHRONOUS rather than deferred to the idle handler, so opening a
# file never shows a frame of unhighlighted text and a caller that inspects tags right
# away sees them.
proc hl_reset {g} {
	gset $g hl_pending 0 ; gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	gset $g hl_enter {} ; gset $g hl_lo 0 ; gset $g hl_hi 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
	if {[gget $g hl_scan] eq ""} return
	hl_ensure $g
}

# Record an edit in group `g` for its next incremental pass. The core echoes every
# change as {start end text}; from that we know the first line touched (sl) and the net
# change in line count (delta). We splice the group's hl_enter by delta so the cached
# entry states BELOW the edit stay index-aligned with the widget — that alignment is
# what lets hl_incremental trust the cache when testing for state convergence. Then we
# widen the dirty range and queue a coalesced pass.
#
# The painted interval is spliced by the same delta, and that is load-bearing rather
# than tidiness: Tk anchors tags to characters, so the correct tags below an edit ride
# the text as it moves. Without the splice every keystroke would look like a jump and
# repaint the whole window instead of a line or two.
proc hl_edit {g p} {
	set scan [gget $g hl_scan] ; set enter [gget $g hl_enter]
	if {$scan eq ""} return
	if {$enter eq ""} { hl_vmark $g ; return }   ;# nothing scanned yet — not a cache miss
	set sl [lindex [split [dict get $p start] .] 0]
	set el [lindex [split [dict get $p end]   .] 0]
	set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
	set delta [expr {$added - ($el - $sl)}]
	set n [llength $enter]
	# Entirely below the frontier: nothing is cached or painted down there, and the
	# frontier makes no claim about it. Let hl_ensure pick it up if it scrolls into view.
	if {$sl > $n} { hl_vmark $g ; return }
	if {$delta > 0} {
		set pad {} ; for {set i 0} {$i < $delta} {incr i} { lappend pad [list "\xEF\xBF\xBFdirty" ""] }
		set enter [linsert $enter $sl {*}$pad]
	} elseif {$delta < 0} {
		# Clamp to the frontier: a deletion reaching past it just truncates the prefix.
		set last [expr {$sl - $delta - 1}]
		if {$last > $n - 1} { set last [expr {$n - 1}] }
		if {$last >= $sl} { set enter [lreplace $enter $sl $last] }
	}
	gset $g hl_enter $enter
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	if {$hi > 0} {
		if {$hi >= $sl} { set hi [expr {max($sl - 1, $hi + $delta)}] }
		if {$lo >  $sl} { set lo [expr {max($sl,     $lo + $delta)}] }
		if {$hi < $lo}  { set lo 0 ; set hi 0 }
		gset $g hl_lo $lo ; gset $g hl_hi $hi
	}
	set dirty [gget $g hl_dirty]
	if {$dirty < 1 || $sl < $dirty} { gset $g hl_dirty $sl }
	set lc [expr {$sl + $added}]
	if {$lc > [gget $g hl_lastchanged]} { gset $g hl_lastchanged $lc }
	hl_schedule $g
}

# Incremental re-highlight of group `g` (the idle handler). Re-scan from the first
# dirty line down, repainting each line and updating its cached entry state, and stop
# as soon as — past the edited region — a line's fresh entry state matches the one
# already cached: the scan state has re-converged, so everything below is unaffected.
#
# The pass runs to the frontier, not to the end of the buffer, and only lines inside
# the painted interval are actually re-tagged; outside it we scan for the state alone.
# An edit that never re-converges (typing "<!--" at the top of a huge file) is capped
# at ::hl_chunk lines: rather than carry resumable state, the frontier is TRUNCATED to
# where the pass got to. That is always legal — the frontier promises nothing below
# itself — and it is what keeps this proc free of continuation bookkeeping.
proc hl_incremental {g} {
	gset $g hl_pending 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	set scan [gget $g hl_scan]
	if {$scan eq ""} { gset $g hl_dirty 0 ; return }
	set enter [gget $g hl_enter]
	set start [gget $g hl_dirty] ; set last [gget $g hl_lastchanged]
	gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	if {$start < 1} return
	set nlines [hl_linecount $t]
	if {$start > $nlines} return
	set E [llength $enter]
	if {$E > $nlines} { set E $nlines }
	if {$start > $E} { hl_vmark $g ; return }      ;# below the frontier
	set lo [gget $g hl_lo] ; set hi [gget $g hl_hi]
	set scanned 0
	set budget $::hl_chunk
	lassign [lindex $enter [expr {$start - 1}]] state param
	for {set L $start} {$L <= $E} {incr L} {
		if {$lo > 0 && $L >= $lo && $L <= $hi} {
			lassign [hl_paint_line $t $scan $L $state $param] state param
		} else {
			lassign [rio::syntax::scan_line $scan [$t get $L.0 "$L.0 lineend"] \
				$state $param] _ state param
		}
		incr scanned
		if {[incr budget -1] <= 0 && $L < $E} {
			set enter [lrange $enter 0 [expr {$L - 1}]]
			foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok [expr {$L + 1}].0 end }
			if {$lo > $L} { set lo 0 ; set hi 0 } elseif {$hi > $L} { set hi $L }
			gset $g hl_lo $lo ; gset $g hl_hi $hi
			hl_vmark $g 0
			break
		}
		if {$L == $E} break                  ;# no cached line below to carry state into
		set next [hl_state $state $param]
		set old [lindex $enter $L]           ;# cached state entering line L+1
		lset enter $L $next
		if {$L >= $last && $next eq $old} break   ;# past the edit and re-converged
	}
	gset $g hl_enter $enter
	gset $g hl_scanned $scanned
	hl_vmark $g   ;# the edit may have exposed lines the window now wants painted
}

# Queue a coalesced incremental pass on group `g`'s idle handler, so a run of
# keystrokes triggers a single re-scan rather than one pass per character.
proc hl_schedule {g} {
	if {[gget $g hl_pending]} return
	gset $g hl_pending 1
	after idle [list hl_incremental $g]
}

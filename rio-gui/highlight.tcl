# rio-gui/highlight.tcl — syntax highlighting and editing modes.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Syntax highlighting (D32). The per-line scanners are in syntax/ and have no
# Tk. The GUI applies them: each token type becomes a text tag `syn:<type>`,
# coloured by the theme's syntax.* role.
#
# Per editor group:
#
#   line 1 ┐
#          │ scanned        hl_enter: the state entering each line, exact,
#   hl_lo ┐│                index i-1 for line i, up to the frontier E
#         ││ painted        hl_lo..hl_hi carry tags (0 0 = none)
#   hl_hi ┘│
#   E     ─┘ the frontier
#          : not scanned    nothing is claimed below E
#   last line
#
# - Only the visible window, plus a margin, is painted (D126). hl_ensure is
#   the one entry point: it grows the frontier toward the window, in chunks
#   that yield to the event loop, and paints what is newly exposed. Every
#   scroll reaches it through edscroll.
# - An edit re-scans from the first dirty line down and stops when a line's
#   entry state matches the cached one: below that nothing changed
#   (hl_edit, hl_incremental). A burst of keystrokes is one pass.
# - Entry states are never guessed: reaching line N means having scanned the
#   lines above it, once.
# - The frontier may always be cut short, since nothing is claimed below it.
# ---------------------------------------------------------------------------

# Load the registry, then every scanner: shipped first, then the user's from
# $XDG_CONFIG_HOME/rio/syntax/, which may replace a shipped one. A broken
# module is reported and skipped.
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
# Editing modes (D38, D41). rio ships the Windows mode; emacs and vi are
# extensions. Loaded like the scanners. The active mode's bindings are on the
# RioMode bind tag, between each text widget and Tk's Text class:
#
#     .eg<g>.t   RioMode   Text   .   all
#
# So a keymap chord (on the widget, D23) beats the mode, and a mode binding
# that `break`s beats Tk's default.
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

# Apply ::edit_mode, for the menu and for boot: detach the old mode, clear the
# tag so no binding leaks, attach the new one. A saved mode that is gone
# falls back to windows.
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

# Column editing belongs to the windows mode; vi and emacs have their own
# block editing. So its toggle is greyed in any other mode.
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

# Pick the scanner for group `g`'s active buffer; "" means none. A language
# picked by hand (the buffer's `lang`, D112) wins, if it is still registered;
# else the file name decides.
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

# View ▸ Language… (D112): pick the current buffer's highlighter by hand.
# The shared picker (D92). No payload is "": pick_dialog returns "" on Cancel.
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

# Scan and re-tag line L of widget `t` from its entry `state`/`param`. Returns
# the state entering line L+1. `clear` 0: the caller already removed the old
# tags for a whole range, which is most of the cost of painting.
proc hl_paint_line {t scan L state param {clear 1}} {
	set line [$t get $L.0 "$L.0 lineend"]
	lassign [rio::syntax::scan_line $scan $line $state $param] spans state param
	if {$clear} {
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $L.0 "$L.0 lineend" }
	}
	foreach {c0 c1 type} $spans { $t tag add syn:$type $L.$c0 $L.$c1 }
	return [list $state $param]
}

# The lines group `g` wants highlighted: those on screen, plus ::hl_margin
# above and below. Asks the widget (@0,y), so a wrapped line counts once. An
# unmapped widget reports height 1: use its configured -height then.
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

# An entry state as one shared object (::hl_states). hl_enter has an entry
# per line, and they are the same two or three values: sharing saves the RAM.
proc hl_state {state param} {
	set key [list $state $param]
	if {[dict exists $::hl_states $key]} { return [dict get $::hl_states $key] }
	if {[dict size $::hl_states] < $::hl_states_max} { dict set ::hl_states $key $key }
	return $key
}

# Grow group `g`'s frontier toward line `target`, at most ::hl_chunk lines
# per call. Scans without painting: only the state is needed from lines above
# the window. If the target is not reached, it re-arms hl_ensure, which aims
# at wherever the window is by then.
#
# The chunk's text is fetched from the widget once and split. The scanner is
# nearly all of this loop's cost (ROADMAP).
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
		# `get` to a lineend omits the last newline, so the split is exactly
		# the lines E..stop.
		foreach line [split [$t get $E.0 "$stop.0 lineend"] "\n"] {
			lassign [rio::syntax::scan_line $scan $line $state $param] _ state param
			lappend enter [hl_state $state $param]  ;# state entering line E+1
			incr E
		}
	}
	gset $g hl_enter $enter
	if {$E < $target} { hl_vmark $g 0 }
}

# Paint lines a..b of group `g` from their cached entry states. The range is
# clamped to the frontier.
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

# Make sure group `g`'s visible window is highlighted. Runs on every scroll,
# so it is cheap when there is nothing to do.
proc hl_ensure {g} {
	gset $g hl_vpending 0
	if {![dict exists $::grp $g]} return
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	if {[gget $g hl_scan] eq ""} return
	# An edit is queued: its pass may cut the frontier, so it runs first.
	# Idle handlers fire in order.
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
		# A jump: what is painted is off-screen, so wiping it cannot flicker.
		foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
		hl_paint_range $g $w0 $w1
		gset $g hl_lo $w0 ; gset $g hl_hi $w1
		return
	}
	# A scroll: paint only the strip that came into range.
	if {$w0 < $lo} { hl_paint_range $g $w0 [expr {$lo - 1}] ; gset $g hl_lo $w0 }
	if {$w1 > $hi} { hl_paint_range $g [expr {$hi + 1}] $w1 ; gset $g hl_hi $w1 }
}

# Queue one hl_ensure on group `g`. `now` uses a timer instead of an idle
# handler: an idle handler that re-registers itself can starve window events.
proc hl_vmark {g {now 0}} {
	if {[gget $g hl_vpending]} return
	gset $g hl_vpending 1
	if {$now} {
		after 0 [list hl_ensure $g]
	} else {
		after idle [list hl_ensure $g]
	}
}

# Drop group `g`'s highlight state and start again from the visible window:
# on open, on a tab switch, and when the scanner changes. The first paint is
# synchronous, so no frame of plain text shows.
proc hl_reset {g} {
	gset $g hl_pending 0 ; gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	gset $g hl_enter {} ; gset $g hl_lo 0 ; gset $g hl_hi 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
	if {[gget $g hl_scan] eq ""} return
	hl_ensure $g
}

# Record an edit in group `g` for the next incremental pass. From the change
# {start end text}: the first line touched (sl) and the change in line count
# (delta).
# - hl_enter is spliced by delta, so the cached states below the edit stay
#   aligned with their lines.
# - hl_lo and hl_hi are shifted by delta too: Tk's tags move with the text,
#   so the lines below the edit are still painted.
# - The dirty range grows and one pass is queued.
proc hl_edit {g p} {
	set scan [gget $g hl_scan] ; set enter [gget $g hl_enter]
	if {$scan eq ""} return
	if {$enter eq ""} { hl_vmark $g ; return }   ;# nothing scanned yet — not a cache miss
	set sl [lindex [split [dict get $p start] .] 0]
	set el [lindex [split [dict get $p end]   .] 0]
	set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
	set delta [expr {$added - ($el - $sl)}]
	set n [llength $enter]
	# Below the frontier: nothing is cached there.
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

# The incremental pass for group `g` (an idle handler). Re-scan from the first
# dirty line down, and stop, once past the edit, when a line's new entry state
# equals the cached one: nothing below changed.
# - Runs to the frontier at most. Only painted lines are re-tagged.
# - An edit that never converges (typing "<!--" at the top of a huge file)
#   stops after ::hl_chunk lines, and the frontier is cut to that line.
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

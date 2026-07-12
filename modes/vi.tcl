# rio — the vi editing mode (AGENTS.md D38).
#
# Modal editing, lean but real: normal / insert / visual states, counts, the core
# motions (h j k l w b e 0 $ gg G, arrows aliased), the operators d c y taking a
# motion (dw, d$, 2dd, yy, cw, …), and x p u i a o O v Escape. Deliberately NOT in
# v1 (see ROADMAP): ex commands, registers (the yank buffer is the X clipboard, so
# dd + p round-trips and even reaches other apps), macros, '.' repeat, marks,
# visual-line. Insert state IS Tk's Text editing — every key falls through to the
# class bindings, so typing, Backspace and arrows behave exactly like the other
# modes; only Escape is intercepted.
#
# All per-state data lives per EDITOR GROUP (like the highlight cache, D33): each
# split half has its own normal/insert state, pending operator and count — a vi
# "window". Positions are computed exclusively with Tk index arithmetic
# ($w index/compare, the tk::Text* helpers) — never through expr, which corrupts
# line.col values ("1.10" -> 1.1). Every edit calls the group proxy (%W), so it
# reaches the core as a buffer.replace like any other keystroke; one operator is
# one replace, hence one undo step.

namespace eval rio::modes::vi {
	variable S {}   ;# group id -> {state normal|insert|visual, count "", op "", opcount "", pendg 0}
}

# --- per-group state --------------------------------------------------------

proc rio::modes::vi::fresh {} {
	return [dict create state normal count "" op "" opcount "" pendg 0]
}

proc rio::modes::vi::st {g key} {
	variable S
	return [dict get $S $g $key]
}

proc rio::modes::vi::stset {g args} {
	variable S
	foreach {k v} $args { dict set S $g $k $v }
}

proc rio::modes::vi::init_group {g} {
	variable S
	if {![dict exists $S $g]} {
		dict set S $g [fresh]
		apply_cursor $g
	}
}

proc rio::modes::vi::clear_pending {g} {
	stset $g count "" op "" opcount "" pendg 0
}

# --- mode plumbing (registry contract) ---------------------------------------

proc rio::modes::vi::attach {tag} {
	bind $tag <KeyPress> {if {[rio::modes::vi::key %W %K %A %s]} break}
	foreach g $::groups { init_group $g }
}

proc rio::modes::vi::detach {tag} {
	variable S
	foreach g $::groups {
		set t [gw $g]
		catch {$t configure -blockcursor 0}
		catch {$t mark unset vianchor}
		catch {$t tag remove sel 1.0 end}
	}
	set S {}
	set ::editmode_status ""
}

# --- chrome: cursor shape + status segment -----------------------------------

proc rio::modes::vi::apply_cursor {g} {
	set t [gw $g]
	if {[st $g state] eq "insert"} {
		catch {$t configure -blockcursor 0}
	} else {
		catch {$t configure -blockcursor 1}
	}
}

proc rio::modes::vi::show_state {g} {
	switch -- [st $g state] {
		insert  { set ::editmode_status "-- INSERT --" }
		visual  { set ::editmode_status "-- VISUAL --" }
		default { set ::editmode_status "" }
	}
	apply_cursor $g
	refresh_status
}

# --- state transitions --------------------------------------------------------

proc rio::modes::vi::to_insert {g w} {
	clear_pending $g
	stset $g state insert
	show_state $g
}

# Leave insert for normal: vi puts the caret on the character LEFT of where
# insertion ended (unless already at the line start).
proc rio::modes::vi::to_normal {g w} {
	stset $g state normal
	clear_pending $g
	if {[$w compare insert > "insert linestart"]} { $w mark set insert "insert -1c" }
	clamp_caret $w
	show_state $g
}

# Escape in normal/visual: drop any pending count/operator; leave visual.
proc rio::modes::vi::cancel {g w} {
	clear_pending $g
	if {[st $g state] eq "visual"} { leave_visual $g $w }
	show_state $g
}

proc rio::modes::vi::leave_visual {g w} {
	stset $g state normal
	catch {$w mark unset vianchor}
	$w tag remove sel 1.0 end
}

# The normal-mode caret sits ON a character, never past the last one.
proc rio::modes::vi::clamp_caret {w} {
	if {[$w compare insert == "insert lineend"] && [$w compare insert != "insert linestart"]} {
		$w mark set insert "insert -1c"
	}
}

# --- the dispatcher -----------------------------------------------------------
# Bound as:  bind <tag> <KeyPress> {if {[rio::modes::vi::key %W %K %A %s]} break}
# Returns 1 to swallow the key (break: Tk's Text class never sees it), 0 to let it
# fall through. `w` is the group's PROXY path; edits made through it reach the core.

proc rio::modes::vi::key {w keysym char kstate} {
	set g [group_of_widget $w]
	if {$g eq ""} { return 0 }
	init_group $g   ;# a group created after attach (a split) self-registers here
	# Bare modifiers never mean anything by themselves.
	if {$keysym in {Shift_L Shift_R Control_L Control_R Alt_L Alt_R Meta_L Meta_R
	                Super_L Super_R Hyper_L Hyper_R Caps_Lock Num_Lock
	                ISO_Level3_Shift Mode_switch}} { return 0 }
	if {[st $g state] eq "insert"} {
		if {$keysym eq "Escape"} { to_normal $g $w ; return 1 }
		return 0   ;# insert state is Tk's Text editing, untouched
	}
	# --- normal / visual ---
	if {$keysym eq "Escape"} { cancel $g $w ; return 1 }
	# Control/Alt combos: the app chords already fired on the path tag; whatever
	# reaches us is swallowed inertly so Tk's C-k/C-d/… can't fire in normal state.
	if {$kstate & 0x4 || $kstate & 0x8} { clear_pending $g ; return 1 }
	# Plain navigation keys Tk handles well; arrows become vi motions (they then
	# respect counts and pending operators).
	if {$keysym in {Prior Next Home End}} { clear_pending $g ; return 0 }
	switch -- $keysym {
		Left  { set char h }
		Right { set char l }
		Up    { set char k }
		Down  { set char j }
	}
	if {$char eq ""} { clear_pending $g ; return 1 }   ;# F-keys, dead keys: inert
	normal_key $g $w $char
	return 1
}

# One printable key in normal or visual state.
proc rio::modes::vi::normal_key {g w ch} {
	set vis  [expr {[st $g state] eq "visual"}]
	set op   [st $g op]
	# A pending g only combines with a second g (the gg motion).
	if {[st $g pendg]} {
		stset $g pendg 0
		if {$ch eq "g"} { do_motion $g $w gg } else { clear_pending $g }
		return
	}
	# Count digits accumulate ("0" only continues a count — alone it is a motion).
	if {[string is digit -strict $ch] && !($ch eq "0" && [st $g count] eq "")} {
		stset $g count "[st $g count]$ch"
		return
	}
	switch -exact -- $ch {
		h - j - k - l - w - b - e - 0 - \$ - G {
			do_motion $g $w $ch
		}
		g { stset $g pendg 1 }
		d - c - y {
			if {$vis} { visual_op $g $w $ch ; return }
			if {$op eq $ch} { do_line_op $g $w $ch ; return }   ;# dd / cc / yy
			if {$op ne ""}  { clear_pending $g ; return }        ;# e.g. d then y: abort
			stset $g op $ch opcount [st $g count] count ""
		}
		x {
			if {$vis} { visual_op $g $w d ; return }
			if {$op ne ""} { clear_pending $g ; return }
			do_x $g $w
		}
		p {
			if {$vis || $op ne ""} { clear_pending $g ; return }
			do_put $g $w
		}
		u {
			clear_pending $g
			if {$vis} { leave_visual $g $w ; show_state $g ; return }
			do_undo
			clamp_caret $w
		}
		i - a - o - O {
			if {$vis || $op ne ""} {
				clear_pending $g
				if {$vis} { leave_visual $g $w ; show_state $g }
				return
			}
			enter_insert $g $w $ch
		}
		v {
			clear_pending $g
			if {$vis} { leave_visual $g $w ; show_state $g ; return }
			stset $g state visual
			$w mark set vianchor insert
			stretch_sel $g $w
			show_state $g
		}
		default { clear_pending $g }
	}
}

# --- counts -------------------------------------------------------------------
# Counts multiply vim-style: 2d3w operates over six words. These are plain integer
# counts — expr is safe HERE (and only here: never on a line.col index).

proc rio::modes::vi::effcount {g} {
	set c [st $g count]   ; if {$c eq ""} { set c 1 }
	set o [st $g opcount] ; if {$o eq ""} { set o 1 }
	return [expr {$c * $o}]
}

# --- motions --------------------------------------------------------------------
# motion_target returns {index class} from the caret: class is how an OPERATOR
# treats the span — exclusive (up to the target), inclusive (through the target's
# character), or linewise (whole lines). A plain move just goes to the index.

proc rio::modes::vi::motion_target {w m n} {
	switch -exact -- $m {
		h {
			set i [$w index insert]
			for {set k 0} {$k < $n} {incr k} {
				if {[$w compare $i == "$i linestart"]} break
				set i [$w index "$i -1c"]
			}
			return [list $i exclusive]
		}
		l {
			set i [$w index insert]
			for {set k 0} {$k < $n} {incr k} {
				if {[$w compare $i >= "$i lineend"]} break
				set i [$w index "$i +1c"]
			}
			return [list $i exclusive]
		}
		j - k {
			set d [expr {$m eq "j" ? 1 : -1}]
			set i [$w index insert]
			for {set k2 0} {$k2 < $n} {incr k2} {
				set i [tk::TextUpDownLine $w $d]
				$w mark set insert $i
			}
			return [list [$w index $i] linewise]
		}
		w {
			set i [$w index insert]
			for {set k 0} {$k < $n} {incr k} {
				set next [tk::TextNextPos $w $i tcl_startOfNextWord]
				if {$next eq "" || [$w compare $next <= $i]} {
					set i [$w index "end -1c"]
					break
				}
				set i [$w index $next]
			}
			return [list $i exclusive]
		}
		b {
			set i [$w index insert]
			for {set k 0} {$k < $n} {incr k} {
				set prev [tk::TextPrevPos $w $i tcl_startOfPreviousWord]
				if {$prev eq "" || [$w compare $prev >= $i]} { set i 1.0 ; break }
				set i [$w index $prev]
			}
			return [list $i exclusive]
		}
		e {
			set i [$w index insert]
			for {set k 0} {$k < $n} {incr k} {
				set next [tk::TextNextPos $w "$i +1c" tcl_endOfWord]
				if {$next eq "" || [$w compare $next <= "$i +1c"]} {
					set i [$w index "end -1c"]
					break
				}
				set i [$w index "$next -1c"]
			}
			return [list $i inclusive]
		}
		0  { return [list [$w index "insert linestart"] exclusive] }
		\$ {
			if {[$w compare "insert lineend" == "insert linestart"]} {
				return [list [$w index insert] inclusive]   ;# empty line: nothing to span
			}
			return [list [$w index "insert lineend -1c"] inclusive]
		}
	}
	return [list [$w index insert] exclusive]
}

# gg / G take their count as a LINE NUMBER (5G = line 5), not a repeat — resolved
# here from the raw digits, clamped to the last line.
proc rio::modes::vi::line_target {w m count} {
	if {$count ne ""} {
		set tgt "$count.0"
		if {[$w compare $tgt > "end -1c"]} { set tgt [$w index "end -1c linestart"] }
		return [$w index $tgt]
	}
	if {$m eq "gg"} { return [$w index 1.0] }
	return [$w index "end -1c linestart"]
}

# Run motion `m`: as a plain caret move, a visual stretch, or an operator target.
proc rio::modes::vi::do_motion {g w m} {
	set op [st $g op]
	set from [$w index insert]
	if {$m in {gg G}} {
		set tgt [line_target $w $m [st $g count]]
		set class linewise
	} else {
		# cw on a non-blank acts like ce (the classic vim exception).
		if {$op eq "c" && $m eq "w" && ![string is space [$w get insert]]} { set m e }
		lassign [motion_target $w $m [effcount $g]] tgt class
		# dw/yw never eat past the line end when the line has content (the other
		# classic exception; without it, dw on the last word swallows the newline).
		if {$op ne "" && $m eq "w" && [$w compare $tgt > "$from lineend"] \
				&& [$w compare $from < "$from lineend"]} {
			set tgt [$w index "$from lineend"]
		}
	}
	if {$m in {j k}} { $w mark set insert $from }  ;# motion_target moved it to measure
	clear_pending $g
	if {$op ne ""} {
		apply_op $g $w $op $from $tgt $class
		return
	}
	$w mark set insert $tgt
	clamp_caret $w
	if {[st $g state] eq "visual"} { stretch_sel $g $w }
	$w see insert
}

# --- operators ------------------------------------------------------------------

# Apply operator `op` over from..to (unordered) with the motion's class. The span
# text goes to the clipboard (linewise spans in canonical trailing-\n form, so `p`
# can tell them apart); d/c delete it through the proxy -> core in ONE replace.
proc rio::modes::vi::apply_op {g w op from to class} {
	if {[$w compare $to < $from]} { set t $from ; set from $to ; set to $t }
	if {$class eq "inclusive"} { set to [$w index "$to +1c"] }
	if {$class eq "linewise"} {
		set ytext "[$w get "$from linestart" "$to lineend"]\n"
		if {$op eq "c"} {
			# cc: clear the lines' content, keep the trailing newline.
			set from [$w index "$from linestart"]
			set to   [$w index "$to lineend"]
		} else {
			set lstart [$w index "$from linestart"]
			set lend   [$w index "$to +1 lines linestart"]
			if {[$w compare $lend >= end]} {
				# The span includes the last line: there is no following newline
				# to take, so eat the PRECEDING one instead (vim's dd on the
				# final line), unless the span starts at the top of the buffer.
				set lend [$w index "end -1c"]
				if {[$w compare $lstart > 1.0]} { set lstart [$w index "$lstart -1c"] }
			}
			set from $lstart ; set to $lend
		}
	} else {
		set ytext [$w get $from $to]
	}
	if {$ytext eq ""} { return }
	clipboard clear ; clipboard append $ytext
	if {$op in {d c}} {
		$w delete $from $to
		$w mark set insert $from
	} else {
		$w mark set insert $from
	}
	if {$op eq "c"} { to_insert $g $w } else { clamp_caret $w }
	$w see insert
}

# dd / cc / yy — the doubled operator works on whole lines, count included (2dd).
proc rio::modes::vi::do_line_op {g w op} {
	set n [effcount $g]
	clear_pending $g
	set to [$w index insert]
	if {$n > 1} { set to [$w index "insert +[expr {$n - 1}] lines"] }
	apply_op $g $w $op [$w index insert] $to linewise
}

# x — delete N characters, never past the line end. The cut lands on the clipboard
# (so xp swaps characters, as in vi).
proc rio::modes::vi::do_x {g w} {
	set n [effcount $g]
	clear_pending $g
	set to [$w index insert]
	for {set k 0} {$k < $n} {incr k} {
		if {[$w compare $to >= "insert lineend"]} break
		set to [$w index "$to +1c"]
	}
	if {[$w compare $to == insert]} return
	clipboard clear ; clipboard append [$w get insert $to]
	$w delete insert $to
	clamp_caret $w
}

# p — put the clipboard after the caret. Text ending in a newline is a LINEWISE
# yank (dd/yy write that form): it opens below the current line; anything else
# goes in charwise after the cursor. A count repeats the text.
proc rio::modes::vi::do_put {g w} {
	set n [effcount $g]
	clear_pending $g
	if {[catch {clipboard get} txt] || $txt eq ""} return
	set txt [string repeat $txt $n]
	if {[string index $txt end] eq "\n"} {
		if {[$w compare "insert +1 lines linestart" >= end]} {
			# Last line: open below it by leading with the newline instead.
			set at [$w index "insert lineend"]
			$w insert $at "\n[string range $txt 0 end-1]"
			$w mark set insert [$w index "$at +1c linestart"]
		} else {
			set at [$w index "insert +1 lines linestart"]
			$w insert $at $txt
			$w mark set insert $at
		}
	} else {
		set at [$w index insert]
		if {[$w compare $at < "$at lineend"]} { set at [$w index "$at +1c"] }
		$w insert $at $txt
		$w mark set insert [$w index "$at +[string length $txt]c -1c"]
	}
	clamp_caret $w
	$w see insert
}

# i a o O — the ways into insert state.
proc rio::modes::vi::enter_insert {g w ch} {
	switch -exact -- $ch {
		a {
			if {[$w compare insert < "insert lineend"]} { $w mark set insert "insert +1c" }
		}
		o {
			$w insert "insert lineend" "\n"
			$w mark set insert "insert +1 lines linestart"
		}
		O {
			set ls [$w index "insert linestart"]
			$w insert $ls "\n"
			$w mark set insert $ls
		}
	}
	$w see insert
	to_insert $g $w
}

# --- visual state -----------------------------------------------------------------

# Keep `sel` spanning anchor..caret INCLUSIVELY (vi selects the character under
# the caret; Tk ranges are half-open, hence the +1c on the far end).
proc rio::modes::vi::stretch_sel {g w} {
	$w tag remove sel 1.0 end
	if {[$w compare vianchor <= insert]} {
		$w tag add sel vianchor "insert +1c"
	} else {
		$w tag add sel insert "vianchor +1c"
	}
}

# d/x, y or c on the visual selection, then back to normal (c: into insert).
proc rio::modes::vi::visual_op {g w op} {
	clear_pending $g
	set ranges [$w tag ranges sel]
	if {[llength $ranges] < 2} { leave_visual $g $w ; show_state $g ; return }
	set from [lindex $ranges 0]
	set to   [lindex $ranges end]
	leave_visual $g $w
	clipboard clear ; clipboard append [$w get $from $to]
	if {$op in {d c}} {
		$w delete $from $to
	}
	$w mark set insert $from
	if {$op eq "c"} { to_insert $g $w } else { clamp_caret $w ; show_state $g }
	$w see insert
}

rio::modes::register vi "Vi (modal)" rio::modes::vi::attach rio::modes::vi::detach

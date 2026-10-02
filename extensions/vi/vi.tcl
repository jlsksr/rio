# rio — the vi editing mode (D38).
#
# MIT, like rio (D121). The notice is in this file because an installed
# extension has no LICENSE beside it (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# Modal editing, small but real:
#
#   states     normal, insert, visual
#   motions    h j k l w b e 0 $ gg G, and the arrows
#   operators  d c y, with a motion and a count (dw, d$, 2dd, yy, cw)
#   also       x p u i a o O v Escape
#
# Not here (see ROADMAP): ex commands, registers, macros, `.`, marks,
# visual-line. The yank buffer is the clipboard, so dd then p works, in
# other apps too. Insert state is Tk's own Text editing; only Escape is
# caught.
#
# State is per editor group (as the highlight cache, D33): each split half
# is its own vi window. Positions are Tk indices, never expr, which turns
# "1.10" into 1.1. Every edit goes through the group proxy (%W), so through
# the core: one operator is one buffer.replace, so one undo step.

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

# Insert to normal. As in vi, the caret steps one character left, unless it
# is at the line start.
proc rio::modes::vi::to_normal {g w} {
	stset $g state normal
	clear_pending $g
	if {[$w compare insert > "insert linestart"]} { $w mark set insert "insert -1c" }
	clamp_caret $w
	show_state $g
}

# Escape in normal or visual: drop the pending count and operator, leave
# visual.
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

# In normal state the caret sits on a character, never past the last one.
proc rio::modes::vi::clamp_caret {w} {
	if {[$w compare insert == "insert lineend"] && [$w compare insert != "insert linestart"]} {
		$w mark set insert "insert -1c"
	}
}

# --- the dispatcher -----------------------------------------------------------
# Returns 1 to swallow the key, 0 to let Tk's Text class have it. `w` is the
# group's proxy.

proc rio::modes::vi::key {w keysym char kstate} {
	set g [group_of_widget $w]
	if {$g eq ""} { return 0 }
	init_group $g   ;# a split made after attach
	# A bare modifier means nothing.
	if {$keysym in {Shift_L Shift_R Control_L Control_R Alt_L Alt_R Meta_L Meta_R
	                Super_L Super_R Hyper_L Hyper_R Caps_Lock Num_Lock
	                ISO_Level3_Shift Mode_switch}} { return 0 }
	if {[st $g state] eq "insert"} {
		if {$keysym eq "Escape"} { to_normal $g $w ; return 1 }
		return 0   ;# insert state is Tk's Text editing, untouched
	}
	# --- normal / visual ---
	# Each command is its own undo step (D90). The core merges a run of
	# one-character edits: right for typing, wrong for x x x. The break
	# also makes i, a and o start a fresh step.
	undo_break
	if {$keysym eq "Escape"} { cancel $g $w ; return 1 }
	# Control and Alt chords: the app's have already run. Swallow the rest,
	# so Tk's Ctrl+K and Ctrl+D do nothing in normal state.
	if {$kstate & 0x4 || $kstate & 0x8} { clear_pending $g ; return 1 }
	# Tk does Page Up/Down, Home and End. The arrows become h j k l, so
	# they take counts and operators.
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
	# g waits for a second g (gg); any other key cancels.
	if {[st $g pendg]} {
		stset $g pendg 0
		if {$ch eq "g"} { do_motion $g $w gg } else { clear_pending $g }
		return
	}
	# Digits build the count. A lone 0 is a motion.
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
# Counts multiply: 2d3w is six words. They are plain integers, so expr is
# safe here, and only here.

proc rio::modes::vi::effcount {g} {
	set c [st $g count]   ; if {$c eq ""} { set c 1 }
	set o [st $g opcount] ; if {$o eq ""} { set o 1 }
	return [expr {$c * $o}]
}

# --- motions --------------------------------------------------------------------
# motion_target returns {index class} from the caret. A plain move goes to
# the index. The class says how an operator takes the span:
#
#   exclusive  up to the target
#   inclusive  through the target's character
#   linewise   whole lines

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

# gg and G read their count as a line number (5G is line 5), clamped to the
# last line.
proc rio::modes::vi::line_target {w m count} {
	if {$count ne ""} {
		set tgt "$count.0"
		if {[$w compare $tgt > "end -1c"]} { set tgt [$w index "end -1c linestart"] }
		return [$w index $tgt]
	}
	if {$m eq "gg"} { return [$w index 1.0] }
	return [$w index "end -1c linestart"]
}

# Run motion `m`: move the caret, stretch the visual selection, or feed an
# operator.
proc rio::modes::vi::do_motion {g w m} {
	set op [st $g op]
	set from [$w index insert]
	if {$m in {gg G}} {
		set tgt [line_target $w $m [st $g count]]
		set class linewise
	} else {
		# cw on a non-blank acts like ce, as in vim.
		if {$op eq "c" && $m eq "w" && ![string is space [$w get insert]]} { set m e }
		lassign [motion_target $w $m [effcount $g]] tgt class
		# dw and yw stop at the line end, as in vim: dw on the last word
		# keeps the newline.
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

# Apply `op` over from..to, in either order, with the motion's class. The
# text goes to the clipboard; a linewise span ends in \n, which is how `p`
# knows it. d and c delete it in one replace.
proc rio::modes::vi::apply_op {g w op from to class} {
	if {[$w compare $to < $from]} { set t $from ; set from $to ; set to $t }
	if {$class eq "inclusive"} { set to [$w index "$to +1c"] }
	if {$class eq "linewise"} {
		set ytext "[$w get "$from linestart" "$to lineend"]\n"
		if {$op eq "c"} {
			# cc empties the lines and keeps the last newline.
			set from [$w index "$from linestart"]
			set to   [$w index "$to lineend"]
		} else {
			set lstart [$w index "$from linestart"]
			set lend   [$w index "$to +1 lines linestart"]
			if {[$w compare $lend >= end]} {
				# The span holds the last line, which has no newline after it.
				# Take the one before instead, unless the span starts at the top.
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

# dd, cc, yy: the doubled operator takes whole lines, count included (2dd).
proc rio::modes::vi::do_line_op {g w op} {
	set n [effcount $g]
	clear_pending $g
	set to [$w index insert]
	if {$n > 1} { set to [$w index "insert +[expr {$n - 1}] lines"] }
	apply_op $g $w $op [$w index insert] $to linewise
}

# x: delete N characters, never past the line end. They go to the
# clipboard, so xp swaps two.
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

# p: put the clipboard after the caret. Text ending in a newline is
# linewise (dd and yy write it so) and opens below the line; other text
# goes in after the caret. A count repeats it.
proc rio::modes::vi::do_put {g w} {
	set n [effcount $g]
	clear_pending $g
	if {[catch {clipboard get} txt] || $txt eq ""} return
	set txt [string repeat $txt $n]
	if {[string index $txt end] eq "\n"} {
		if {[$w compare "insert +1 lines linestart" >= end]} {
			# On the last line, lead with the newline instead.
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

# i a o O: the ways into insert state.
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

# Keep `sel` over anchor..caret, both included. Tk ranges are half-open,
# hence the +1c.
proc rio::modes::vi::stretch_sel {g w} {
	$w tag remove sel 1.0 end
	if {[$w compare vianchor <= insert]} {
		$w tag add sel vianchor "insert +1c"
	} else {
		$w tag add sel insert "vianchor +1c"
	}
}

# d, x, y or c on the selection, then back to normal; c goes to insert.
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

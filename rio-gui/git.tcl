# rio-gui/git.tcl — the Git pane.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The git pane: a view of the core's git.* ops on the open project.
#
#   ┌ ⎇ main                 ↩  ⟳ ┐   ↩ only while there are changes
#   │ M  src/main.tcl               │   the changes, a rich list (D43)
#   │ ?? notes.txt                  │
#   ├───────────────────────────────┤
#   │ the selected change's diff    │   hidden until a change is selected
#   ├───────────────────────────────┤
#   │ [message          ] ＋ ✓ Commit│   only while something is staged
#   └───────────────────────────────┘
#
# A row's payload is its change dict {x y path ?orig?}, or "" for a
# placeholder such as "(clean)". No file-watching: ⟳ re-reads.
# ---------------------------------------------------------------------------
# Show the diff area with `text`.
proc git_show_diff {text} {
	.pgit.diff configure -state normal
	.pgit.diff delete 1.0 end
	.pgit.diff insert 1.0 $text
	.pgit.diff configure -state disabled
	if {[lsearch -exact [pack slaves .pgit] .pgit.diff] < 0} {
		pack .pgit.diff -side top -fill both -expand 1
	}
}
proc git_hide_diff {} {
	.pgit.diff configure -state normal
	.pgit.diff delete 1.0 end
	.pgit.diff configure -state disabled
	pack forget .pgit.diff
}

proc refresh_git {} {
	set b .pgit.well.body
	rl_begin $b
	git_hide_diff
	# Without a folder, git.* would use rio's own cwd: the wrong repo.
	if {[dict get [rio_call project.get {}] result root] eq ""} {
		.pgit.hdr.branch configure -text "git"
		git_placeholder "(open a folder)"
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	set resp [rio_call git.status {}]
	if {![dict get $resp ok]} {
		.pgit.hdr.branch configure -text "git"
		set code [dict get $resp error code]
		git_placeholder [expr {$code eq "bad_request" ? "(not a git repository)" \
			: [dict get $resp error message]}]
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	set r [dict get $resp result]
	.pgit.hdr.branch configure -text "⎇ [dict get $r branch]"
	set changes [dict get $r changes]
	if {![llength $changes]} {
		git_placeholder "(clean)"
		git_commit_bar 0
		git_discard_all_button 0
		rl_end $b
		return
	}
	# Something is staged when a change's X is neither " " nor "?".
	set staged 0
	foreach c $changes {
		git_render_row $c
		set x [dict get $c x]
		if {$x ne " " && $x ne "?"} { set staged 1 }
	}
	git_commit_bar $staged
	git_discard_all_button [llength $changes]   ;# ↩ in the header, only while there's something to discard (D93)
	rl_end $b
}

# A non-selectable message row (no folder / not a repo / clean). Two-space indent
# keeps it clear of the status gutter column. Caller has the body in -state normal.
proc git_placeholder {text} {
	.pgit.well.body insert end "  $text\n"
	rl_row .pgit.well.body 0 ""
}
# One change row: the two porcelain status chars (each colour-tagged by kind), a
# space, then the path. Payload is the whole change dict.
proc git_render_row {c} {
	set b .pgit.well.body
	foreach ch [list [dict get $c x] [dict get $c y]] {
		set tag [git_status_tag $ch]
		if {$tag eq ""} { $b insert end $ch } else { $b insert end $ch $tag }
	}
	$b insert end " [dict get $c path]\n"
	rl_row $b 1 $c
}
# Colour tag for a git porcelain status char (see apply_theme). "" for a blank.
proc git_status_tag {ch} {
	switch -- $ch {
		A - ? { return gitadd }
		D     { return gitdel }
		" "   { return "" }
		default { return gitmod }
	}
}

# A change was selected: show its diff. Staged and not changed again in the
# worktree: the staged diff; else the worktree diff. An untracked file has
# no diff.
proc git_pick {row} {
	if {$row eq ""} { git_hide_diff ; return }
	set x [dict get $row x] ; set y [dict get $row y]
	set staged [expr {$y eq " " && $x ne " " && $x ne "?"}]
	set resp [rio_call git.diff [dict create path [dict get $row path] staged $staged]]
	if {![dict get $resp ok]} {
		git_show_diff [dict get $resp error message]
		return
	}
	set d [dict get $resp result diff]
	git_show_diff [expr {$d eq "" ? "(no textual diff)" : $d}]
}

# Right-click a change: Open, Copy Path, Stage, Unstage, Discard (D44).
# git_menu_build fills the menu, so a headless test can read it.
proc git_context_menu {payload X Y} {
	catch {destroy .gitmenu}
	menu .gitmenu -tearoff 0
	git_menu_build .gitmenu $payload
	tk_popup .gitmenu $X $Y
}
proc git_menu_build {m payload} {
	set path [dict get $payload path]
	# An untracked directory is one row, with a trailing slash: no Open, and
	# "Stage folder".
	set isdir [string match "*/" $path]
	set root [dict get [rio_call project.get {}] result root]
	set abs  [file join $root $path]
	if {!$isdir} { $m add command -label "Open" -command [list do_open $abs] }
	$m add command -label "Copy Path" -command [list rio_copy_clip $abs]
	set x [dict get $payload x] ; set y [dict get $payload y]
	$m add separator
	if {$y ne " "} {
		$m add command -label [expr {$isdir ? "Stage folder" : "Stage"}] \
			-command [list do_git add $path]
	}
	if {$x ne " " && $x ne "?"} {
		$m add command -label "Unstage" -command [list do_git unstage $path]
	}
	# Discard (D80), behind a confirmation. A new file ("?" or "A") is
	# deleted, so the entry says Delete…; a tracked change is reverted.
	$m add separator
	if {$x eq "?" || $x eq "A"} {
		$m add command -label "Delete…"          -command [list git_discard_confirm $path 1]
	} elseif {$x eq "R"} {
		# A rename goes back to its old name (D97): pass that name on.
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm $path 0 [dict get $payload orig]]
	} else {
		$m add command -label "Discard Changes…" -command [list git_discard_confirm $path 0]
	}
}

# Run git.add or git.unstage on a path and repaint. The path may be absolute
# or relative to the repo.
proc do_git {op path} {
	set resp [rio_call git.$op [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	refresh_dock
}

# Confirm, then discard one change (git.discard, D80). The question says what
# will happen: a new file (`isnew`) is deleted, a tracked one reverted, a
# rename (`orig`, D97) goes back to its old name. The default is No.
proc git_discard_confirm {path isnew {orig ""}} {
	if {$isnew} {
		set q "Delete “$path”?\n\nThis is a new file, not in the last commit — deleting it can't be undone."
	} elseif {$orig ne ""} {
		set q "Discard the rename of “$orig”?\n\nIt will go back to its old name and its last committed contents. This can't be undone."
	} else {
		set q "Discard changes to “$path”?\n\nIt will return to the last committed version. This can't be undone."
	}
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — discard" -message $q] ne "yes"} {
		return
	}
	set resp [rio_call git.discard [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	refresh_dock
	if {[dict get $resp result action] eq "remove"} {
		git_flash "✓ deleted"
	} elseif {$orig ne ""} {
		git_flash "✓ rename undone"
	} else {
		git_flash "✓ discarded changes"
	}
}

# Show the header's ↩ (discard all, D93) only while there are changes, and
# keep the count for the confirmation.
proc git_discard_all_button {n} {
	set ::git_change_count $n
	if {$n > 0} {
		if {[lsearch -exact [pack slaves .pgit.hdr] .pgit.hdr.discard] < 0} {
			pack .pgit.hdr.discard -side right
		}
	} else {
		pack forget .pgit.hdr.discard
	}
}

# Confirm, then discard every change (git.discard_all, D93), in one core
# call. The question says what is reverted, what is deleted and what is left
# alone. The default is No.
proc git_discard_all_confirm {} {
	if {$::git_change_count <= 0} return
	set q "Discard all $::git_change_count [git_plural $::git_change_count change] in this project?\n\nEvery changed file goes back to its last committed version, and files that were never committed are deleted. Files git ignores are left alone.\n\nThis can't be undone."
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — discard all" -message $q] ne "yes"} {
		return
	}
	set resp [rio_call git.discard_all {}]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	set n [dict get $resp result count]
	refresh_dock
	git_flash "✓ discarded $n [git_plural $n change]"
}
# "1 change", "2 changes".
proc git_plural {n word} {
	return [expr {$n == 1 ? $word : "${word}s"}]
}

# Show the commit bar (D45) only while something is staged. Hiding it clears
# the message.
proc git_commit_bar {show} {
	if {$show} {
		if {[lsearch -exact [pack slaves .pgit] .pgit.commit] < 0} {
			pack .pgit.commit -side bottom -fill x
		}
	} else {
		pack forget .pgit.commit
		.pgit.commit.msg delete 0 end
		.pgit.commit.body delete 1.0 end
		git_commit_body_set 0
	}
}

# Show or hide the description below the summary (D80). The bar is packed
# again each time, so the order is fixed. Hidden by default.
proc git_commit_body_set {show} {
	foreach w {.pgit.commit.body .pgit.commit.msg .pgit.commit.go .pgit.commit.more} {
		catch {pack forget $w}
	}
	if {$show} { pack .pgit.commit.body -side bottom -fill x -padx 4 -pady {0 3} }
	pack .pgit.commit.go   -side right -padx {2 4} -pady 2
	pack .pgit.commit.more -side right -pady 2
	pack .pgit.commit.msg  -side left -fill x -expand 1 -padx {4 2} -pady 2
	set ::git_commit_body_shown $show
	.pgit.commit.more configure -text [expr {$show ? "−" : "＋"}]
	if {$show} { git_commit_body_hint ; focus .pgit.commit.body }
}
proc git_commit_body_toggle {} { git_commit_body_set [expr {!$::git_commit_body_shown}] }

# The description's placeholder, shown while it is empty.
proc git_commit_body_hint {args} {
	if {[string trim [.pgit.commit.body get 1.0 end]] eq ""} {
		place .pgit.commit.body.ph -x 4 -y 3 -anchor nw
	} else {
		place forget .pgit.commit.body.ph
	}
}

# The summary's placeholder, shown while it is empty. Run by a trace on
# git_commit_msg.
proc git_commit_hint {args} {
	global git_commit_msg
	if {$git_commit_msg eq ""} {
		place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
	} else {
		place forget .pgit.commit.msg.ph
	}
}

# Commit what is staged. The message is the summary, or
# "summary\n\ndescription". An empty summary is refused with a flash. On
# success the header shows the new short hash.
proc git_commit {} {
	set summary [string trim [.pgit.commit.msg get]]
	if {$summary eq ""} { git_flash "enter a commit message" ; focus .pgit.commit.msg ; return }
	set body [string trim [.pgit.commit.body get 1.0 end]]
	set msg $summary
	if {$body ne ""} { append msg "\n\n" $body }
	set resp [rio_call git.commit [dict create message $msg]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	.pgit.commit.msg delete 0 end
	.pgit.commit.body delete 1.0 end
	git_commit_body_set 0
	refresh_dock
	git_flash "✓ committed [dict get $resp result hash]"
}

# Show a message in the git header for 2.5 s, then repaint.
proc git_flash {text} {
	.pgit.hdr.branch configure -text $text
	# The op usually announced fs.changed too (D94), and that repaint would
	# wipe the message. Cancel it while the git pane shows; the refresh_git
	# scheduled below repaints anyway.
	if {$::dock_pane eq "git" && $::fs_changed_after ne ""} {
		after cancel $::fs_changed_after
		set ::fs_changed_after "" ; set ::fs_changed_paths {}
	}
	after cancel refresh_git
	after 2500 refresh_git
}

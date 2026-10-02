# rio-gui/git.tcl — the Git pane.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The git pane (D7 read layer in a view). Shares the dock with the
# file pane — only one shows at a time. A dumb view of the core's git.* against
# the open project (git.* now defaults its cwd to the project root): git.status
# fills the branch + changed-file list, selecting a file fetches git.diff into a
# read-only diff area. No file-watching, so a Refresh button re-reads on demand.
# The change list is an rl_* rich-list too (D43) — same well/bands/nav as the file
# pane — each row's payload being its change dict {x y path ...} (or "" for a
# placeholder like "(clean)").
# ---------------------------------------------------------------------------
# The diff area is collapsible (D13): hidden until a file is picked, so the
# default git pane is just a full-height change list — consistent with the file
# pane — and the diff slides in below (sharing the height) only when there is one
# to read, instead of sitting empty and looking like dead space.
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
	# With no folder open, git.* would fall back to rio's OWN process cwd and show
	# the wrong repo — so the pane is honest about needing a project first.
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
	# The commit bar shows only when the index has something to commit: a change whose
	# X (staged column) is a real status char — not clean " " and not untracked "?".
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

# Selecting a changed file (onselect) shows its diff. A path staged but not also
# modified in the worktree (X set, Y blank) is shown via --cached; otherwise the
# worktree diff. An untracked file has no textual diff — git returns empty, said
# plainly. The payload is the change dict ("" for a placeholder row).
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

# Right-click a change row (oncontext): Open the file (file rows only — see below), Copy
# Path, and Stage/Unstage from its X/Y (D44). The porcelain path is repo-root-relative and
# the project root is the repo root, so it doubles as git's cwd-relative path; Open needs
# the abspath.
# git_menu_build fills the menu (separated for headless inspection); the wrapper posts.
proc git_context_menu {payload X Y} {
	catch {destroy .gitmenu}
	menu .gitmenu -tearoff 0
	git_menu_build .gitmenu $payload
	tk_popup .gitmenu $X $Y
}
proc git_menu_build {m payload} {
	set path [dict get $payload path]
	# A wholly untracked DIRECTORY is one porcelain row, marked only by its trailing slash
	# — which survives here, though `file join` strips it from the tree's map. It is a
	# folder, so it has no text to open and staging it stages everything under it: drop
	# Open, and say "folder" where the act is the folder's. Reaching one file inside it is
	# the file tree's job (nav_menu_git), since only the tree lists them.
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
	# Discard is destructive, so it's confirm-gated (like file Delete, D48) and set apart
	# by a separator. A NEW file — untracked ("?") or a staged addition ("A") — has no
	# committed version, so discarding DELETES it; a tracked change reverts to the last
	# commit. Word each for what it actually does (D80).
	$m add separator
	if {$x eq "?" || $x eq "A"} {
		$m add command -label "Delete…"          -command [list git_discard_confirm $path 1]
	} elseif {$x eq "R"} {
		# A rename discards back to the OLD name (D97), which is a different promise from
		# "reverts its contents" — so hand the confirm the name it will reappear under.
		# Only this door can: porcelain carries the original path, the file tree doesn't.
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm $path 0 [dict get $payload orig]]
	} else {
		$m add command -label "Discard Changes…" -command [list git_discard_confirm $path 0]
	}
}

# Run a git write op (add | unstage) on a path, then repaint the shown pane so the
# new flag / change list appears. The path may be a file-pane abspath or a git-pane
# repo-relative path — git resolves both against the project-root cwd.
proc do_git {op path} {
	set resp [rio_call git.$op [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	refresh_dock
}

# Confirm, then discard a change row's local changes (git.discard, D80). `isnew` picks the
# wording — a new file is DELETED (nothing committed to fall back to); a tracked file
# REVERTS to the last commit. `orig` is a rename's original path (D97), where reverting
# also moves the file back under that name — say so, because the file vanishing from the
# tree under the name you right-clicked would otherwise read as a deletion. Both are
# irreversible, so the default button is No (mirrors the file Delete confirm, D48). On
# success the pane repaints and the header flashes the outcome.
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

# Show or hide the header's ↩ button — "discard all" (D93) — and stash the change count the
# confirm will quote. refresh_git passes the number of changes, so the button is packed
# exactly when there is something to discard: the commit bar's rule (D45, the D36 "only when
# needed" bar) applied to the header, which also keeps a destructive control off the chrome
# of a clean repo. Packed with -side right AFTER ⟳ was, so it sits to ⟳'s left.
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

# Confirm, then discard EVERY change in the project (git.discard_all, D93). One core call,
# not one per file — the core does the whole sweep in git and returns how many changes it
# found. This is the most destructive thing rio can do to a working tree, so the question
# spells out both halves (changed files revert, never-committed files are deleted), says
# what it does NOT touch, and defaults to No like every other irreversible action (D48, D80).
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
# "1 change" / "2 changes" — the count is real data (it says how much is about to go), so
# it can be 1, and "1 changes" in a warning dialog reads as a bug.
proc git_plural {n word} {
	return [expr {$n == 1 ? $word : "${word}s"}]
}

# Show or hide the commit bar (D45). refresh_git calls this with 1 when the index has a
# staged change to commit, 0 otherwise — so the bar is present exactly when committing is
# meaningful. Packed at the very bottom of the git pane (below the change list and any
# diff). Hiding clears the entry so a stale message never lingers into the next repo.
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

# Show/hide the optional multi-line description below the summary (D80). Re-packs the
# whole bar each time so the row order is deterministic: body (when shown) claims the
# bottom, then Commit + ＋ on the right, the summary filling the left. `＋`/`−` on the
# toggle says which way it goes. Collapsed is the default — most commits are one line,
# so the bar stays a single row until the user asks for more (the D36 "only when needed"
# quality bar, applied within the bar).
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

# The body's greyed placeholder, shown only while the description is empty (the same
# device as the summary hint — a child label placed over the text widget, never part of
# `.body get`, so the commit assembly stays honest).
proc git_commit_body_hint {args} {
	if {[string trim [.pgit.commit.body get 1.0 end]] eq ""} {
		place .pgit.commit.body.ph -x 4 -y 3 -anchor nw
	} else {
		place forget .pgit.commit.body.ph
	}
}

# Show the greyed "message" hint exactly while the commit entry is empty; hide it once
# the user has typed anything. Driven by the git_commit_msg textvariable trace, so it
# tracks typing, clearing, and refresh-driven resets alike.
proc git_commit_hint {args} {
	global git_commit_msg
	if {$git_commit_msg eq ""} {
		place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
	} else {
		place forget .pgit.commit.msg.ph
	}
}

# Commit the staged index with the bar's summary line, plus the optional description
# body joined as "summary\n\nbody" — git's own convention (subject, blank line, body),
# which `git commit -m` records verbatim, so the core op is unchanged. An empty (or
# whitespace) SUMMARY is refused quietly — a flash, focus kept, no core call — rather than
# letting git abort; an empty body just adds nothing. On success the staged changes vanish,
# so refresh_dock auto-hides the bar; the header then flashes the new short hash.
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

# Briefly show a message in the git header's branch label, then restore it. Reuses the
# header rather than adding a status widget; the scheduled refresh_git repaints the real
# branch line. Runs after refresh_dock, so the flash survives that repaint.
proc git_flash {text} {
	.pgit.hdr.branch configure -text $text
	# The op that flashed here has usually just announced fs.changed as well (D94), and
	# that idle repaint would wipe the message before anyone read it. Drop it while the
	# git pane is the one showing — the scheduled refresh_git below repaints all the same,
	# once the flash has had its 2.5s. With another pane shown the settle is left alone:
	# it is repainting the file tree, which the flash has no claim on.
	if {$::dock_pane eq "git" && $::fs_changed_after ne ""} {
		after cancel $::fs_changed_after
		set ::fs_changed_after "" ; set ::fs_changed_paths {}
	}
	after cancel refresh_git
	after 2500 refresh_git
}

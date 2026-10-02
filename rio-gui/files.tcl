# rio-gui/files.tcl — the Files pane and its file actions.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The file pane. A
# lazy tree over the core's project root (D87): it lists ONE directory per fs.list
# call, and unfolds a directory in place on demand rather than the core walking a
# whole repo. The core owns "which folder is open" (project.*); this pane is a dumb
# view of it — opening a folder goes through project.open and the pane repaints
# from the project.opened event (D3), the same event-driven path as buffer edits.
# ::nav_root is the open project root (absolute); ::nav_expanded is the set (a dict
# used as a set) of absolute dir paths currently unfolded. The pane is an rl_* rich-list
# whose per-row payload is {type abspath}, so a click knows what it hit.
# ---------------------------------------------------------------------------
proc open_folder {path} {
	set resp [rio_call project.open [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error "Could not open folder $path:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	return 1   ;# the pane repaints via the project.opened event (on_project_opened)
}

proc on_project_opened {p} {
	set ::nav_root [dict get $p root]
	set ::nav_expanded [dict create]   ;# a fresh project shows the collapsed root (D87)
	# Remember this folder so the next launch reopens it (D88). Local cores only: a remote
	# root is a path on the SERVER, meaningless to reopen against a local core (and it must
	# not clobber the remembered local project). prefs_save self-gates on ::rio_started, so
	# this no-ops during the boot reopen and persists once the user opens a folder live.
	if {!$::core_remote} { set ::last_project $::nav_root ; prefs_save }
	refresh_dock
}

# Repaint whichever dock pane is showing (the other repaints when next shown). rio
# does no file-watching, so the panes' state is refreshed at the moments rio knows
# something might have changed — opening a folder, saving a file, an fs.changed from the
# core (D47), or regaining OS focus (app_focus_event) — rather than live.
proc refresh_dock {} {
	rio::panel::refresh $::dock_pane
}

# Repaint the files pane as a tree from the project root (D87): dirs then files at each
# level (each group dictionary-sorted by the core already), an unfolded dir's children
# rendered indented right below it. Each row is one line: a 2-char git-status gutter
# (blank when clean, D43), one indent step (two spaces) per depth, a mono glyph icon
# (▸ folded dir · ▾ unfolded dir · ▪ file, all U+25xx so they render monochrome, never
# emoji), then the name. The body is an rl_* rich-list.
proc populate_nav {} {
	set b .pfiles.well.body
	rl_begin $b
	set ::nav_row_depth [dict create]   ;# path -> tree depth, for the arrow-click hit test (D87)
	# Probe the root once. Its own folder can vanish under us (deleted on disk mid-run); the
	# core's fs.list is the stat that also works in remote mode (the GUI can't see a server
	# path). A gone root is not an error worth a dialog — it CLOSES the project: forget it as
	# the reopen target if it was the remembered one (D88), and fall through to the placeholder.
	set entries {}
	if {$::nav_root ne ""} {
		set probe [rio_call fs.list [dict create path $::nav_root]]
		if {[dict get $probe ok]} {
			set entries [dict get $probe result entries]
		} else {
			if {$::nav_root eq $::last_project} { set ::last_project "" }
			set ::nav_root ""
			set ::nav_expanded [dict create]
		}
	}
	if {$::nav_root eq ""} {
		.pfiles.hdr.head configure -text "(no folder)"
		$b insert end "    Open a folder…\n"
		rl_row $b 0 [list none ""]
		set ::nav_git {}
		rl_end $b
		return
	}
	.pfiles.hdr.head configure -text [file tail $::nav_root]
	set git [nav_git_map $::nav_root]
	set ::nav_git $git   ;# stashed so the row context menu can read status (D44)
	nav_render_entries $::nav_root 0 $git $entries
	rl_end $b
}

# Render one directory level and recurse into whichever of its subdirs are unfolded
# (::nav_expanded). A folded dir shows ▸, an unfolded one ▾ with its children indented one
# step deeper. An fs.list error is reported once but leaves the siblings already drawn.
# (A vanished subdir raises no error here: its parent's listing simply omits it, so this is
# never called for it — only a live race or a permission fault reaches the report.)
proc nav_render_level {dir depth git} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	nav_render_entries $dir $depth $git [dict get $resp result entries]
}

# Draw one already-listed level's rows (dirs then files, core-sorted), recursing into each
# unfolded subdir. Split from nav_render_level so the root's listing — fetched once in
# populate_nav to probe for a vanished project — is not fetched a second time.
proc nav_render_entries {dir depth git entries} {
	foreach grp {dir file} {
		foreach e $entries {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			if {!$::show_hidden && [string index $name 0] eq "."} continue  ;# hide dotfiles (View ▸ Show Hidden Files)
			set path [file join $dir $name]
			if {$grp eq "dir"} {
				set open [dict exists $::nav_expanded $path]
				nav_render_row dir $path "$name/" [expr {$open ? "▾" : "▸"}] \
					$depth [nav_dir_status $git $path]
				if {$open} { nav_render_level $path [expr {$depth + 1}] $git }
			} else {
				nav_render_row file $path $name "▪" $depth [nav_file_status $git $path]
			}
		}
	}
}

# Is directory $d currently on screen in the pane? True for the root and any unfolded dir
# — those are the levels whose children are drawn, so a change under one is worth a repaint
# (the fs.changed / focus-return refresh guards, D47). A folded dir's contents aren't shown.
proc nav_dir_visible {d} {
	return [expr {$d eq $::nav_root || [dict exists $::nav_expanded $d]}]
}

# Toggle: show or hide dotfile / hidden entries in the Files pane, then repaint and persist.
# Off by default, so a fresh pane hides `.git/` and other dotfiles the way `ls` does; on
# reveals them. populate_nav does the filtering (a name-starts-with-"." skip), so this just
# re-lists the shown directory. Three doors drive the same ::show_hidden global through this
# one applier — the View menu, the Preferences window, and the pane-header glyph button — so
# all three (and the header glyph) stay in sync for free.
proc apply_show_hidden {} {
	nav_hidden_glyph
	populate_nav
	prefs_save
}
# The pane-header glyph reflects the current state (a filled ◉ dot when hidden files show,
# a faint dotted ◌ when they are hidden) — a bare glyph, no tooltip, like the ⟳ refresh
# beside it. Kept in sync by apply_show_hidden, so every door updates it. No-op before the
# header exists (called from the boot applier once the pane is built).
proc nav_hidden_glyph {} {
	if {![winfo exists .pfiles.hdr.hidden]} return
	.pfiles.hdr.hidden configure -text [expr {$::show_hidden ? "◉" : "◌"}]
	tooltip .pfiles.hdr.hidden [expr {$::show_hidden ? "Hide hidden files" : "Show hidden files"}]
}
# The header button's action: flip the global and run the shared applier.
proc nav_toggle_hidden {} {
	set ::show_hidden [expr {!$::show_hidden}]
	apply_show_hidden
}

# The git status for the open project, as an abspath -> XY-status dict (the two
# porcelain chars). Empty when there is no repo — a plain file pane, no gutter. The
# porcelain paths are repo-root-relative and rio opens the repo root as the project,
# so we anchor them at $root. (D43)
proc nav_git_map {root} {
	set map [dict create]
	set r [rio_call git.status {}]
	if {![dict get $r ok]} { return $map }
	foreach c [dict get $r result changes] {
		dict set map [file join $root [dict get $c path]] \
			"[dict get $c x][dict get $c y]"
	}
	return $map
}
# A file's one-letter flag: the worktree char if any, else the staged one (so a bare
# stage still shows). "" when the path is clean / untracked-parent.
proc nav_file_status {git path} {
	if {![dict exists $git $path]} { return "" }
	set xy [dict get $git $path]
	set y [string index $xy 1]
	return [expr {$y ne " " ? $y : [string index $xy 0]}]
}
# A directory's rollup flag: "·" when it contains (or is) a change, else "". Lets the
# flat one-dir navigator hint where changes hide without walking into them. An
# untracked directory is reported by porcelain as the directory itself, so we match
# both the dir's own path and anything beneath it.
proc nav_dir_status {git path} {
	if {[dict exists $git $path]} { return "·" }
	foreach p [dict keys $git] {
		if {[string match "$path/*" $p]} { return "·" }
	}
	return ""
}
# Does PATH sit inside a directory git reports as untracked? Porcelain names such a
# directory once and nothing below it, so its files never appear in the status map and
# the row menu has to ask this instead of a lookup. Walks up to the project root: the
# untracked directory can be any ancestor, not just the immediate parent.
proc nav_untracked_parent {git path} {
	for {set d [file dirname $path]} {$d ne [file dirname $d]} {set d [file dirname $d]} {
		if {[dict exists $git $d] && [string index [dict get $git $d] 0] eq "?"} { return 1 }
		if {$d eq $::nav_root} break
	}
	return 0
}

# Append one navigator row: a 2-char status gutter (the flag glyph + a space, or two
# spaces when clean) — kept in a fixed left column so flags stay aligned across depths —
# then one indent step (two spaces) per tree depth, then the type glyph (tagged navicon)
# and the label. Records {type abspath} as the row payload. Caller has the body -state normal.
proc nav_render_row {type path label glyph depth status} {
	set b .pfiles.well.body
	if {$status eq ""} {
		$b insert end "  "
	} else {
		$b insert end $status [nav_status_tag $status] " "
	}
	$b insert end [string repeat "  " $depth]
	$b insert end $glyph navicon " $label\n"
	rl_row $b 1 [list $type $path]
	dict set ::nav_row_depth $path $depth   ;# so a click knows where this row's name starts
}
# Colour tag for a files-pane status flag (see apply_theme for the colours).
proc nav_status_tag {s} {
	switch -- $s {
		A - ? { return navadd }
		D     { return navdel }
		·     { return navdirty }
		default { return navmod }
	}
}

# Double-click / Enter on a row (onactivate): unfold/fold a directory in place, or open
# a file in a tab. The payload is the row's {type abspath}. (D87 — the tree replaced the
# old descend-into-a-dir navigation; single-click and arrows just move the selection.)
proc nav_open {payload} {
	lassign $payload type path
	switch -- $type {
		dir  { nav_toggle_expand $path }
		file { do_open $path }
	}
}
# Flip a directory between folded and unfolded, then repaint. Folding keeps any descendant
# expand-state in ::nav_expanded, so re-opening the dir restores the sub-shape it had.
proc nav_toggle_expand {path} {
	if {[dict exists $::nav_expanded $path]} {
		dict unset ::nav_expanded $path
	} else {
		dict set ::nav_expanded $path 1
	}
	populate_nav
	session_save   ;# the unfolded set changed — record it so the next launch resumes it (D89)
}

# Click routing for the files pane (D87). A folder unfolds on a SINGLE click of its arrow —
# the twisty and the indent/gutter left of the name — while its NAME is reserved for
# double-click (dirs toggle, files open). This splits the plain rl_* click, so it is wired
# only on the files body (the git pane keeps the default select-on-click).
#
# nav_col_is_arrow is the pure decision (kept separate so it is testable without pixels):
# a dir row's name begins at char column 2 (git gutter) + 2·depth (indent) + 2 (glyph +
# space); a click left of that is on the arrow. A file row has no arrow.
proc nav_col_is_arrow {type depth col} {
	return [expr {$type eq "dir" && $col < 2 * $depth + 4}]
}
proc nav_hit_arrow {w row x y} {
	if {![rl_selectable $w $row]} { return 0 }
	lassign [rl_payload $w $row] type path
	set depth [expr {[dict exists $::nav_row_depth $path] ? [dict get $::nav_row_depth $path] : 0}]
	set col [lindex [split [$w index @$x,$y] .] 1]
	return [nav_col_is_arrow $type $depth $col]
}
# Single click: select the row; if it landed on a folder's arrow, unfold/fold it too.
proc nav_b1 {w x y} {
	focus $w
	if {![llength $::rl_rows($w)]} return
	set row [rl_row_at $w $x $y]
	rl_select $w $row
	if {[nav_hit_arrow $w $row $x $y]} { nav_open [rl_payload $w $row] }
}
# Double click: activate (dir toggles, file opens) UNLESS it fell on the arrow — there the
# first click's single-click handler already toggled, so the second must not toggle back.
proc nav_b1_double {w x y} {
	if {![llength $::rl_rows($w)]} return
	set row [rl_row_at $w $x $y]
	rl_select $w $row 0
	if {![nav_hit_arrow $w $row $x $y]} { rl_activate $w }
}

# Right-click a file/dir row (oncontext): a menu of actions ABOUT THIS ROW (the
# UI-design bar — scoped to what was clicked, like the tab menu). Rebuilt each popup
# so the git items reflect the row's current status (read from the ::nav_git stash).
# Open + Copy Path always; git stage/unstage/track appear only when they apply (D44).
# nav_menu_build fills a menu (separated so a headless test can inspect entries
# without posting); nav_context_menu wraps it in the popup.
proc nav_context_menu {payload X Y} {
	catch {destroy .navmenu}
	menu .navmenu -tearoff 0
	nav_menu_build .navmenu $payload
	tk_popup .navmenu $X $Y
}
proc nav_menu_build {m payload} {
	lassign $payload type path
	$m add command -label "Open" -command [list nav_open $payload]
	if {$type eq "file"} {
		$m add command -label "Copy Path" -command [list rio_copy_clip $path]
	}
	nav_menu_fs $m $type $path
	nav_menu_git $m $type $path
}
# Append the file-management verbs (D48). New File/New Folder create in the row's own
# directory (D87): a folder row → inside that folder (and it auto-unfolds so the new entry
# shows); a file row → alongside it; they appear whenever a folder is open. Rename/Delete
# act on the clicked row — any real file/dir row now (the tree has no ".." placeholder to
# exclude), never the no-folder placeholder. Names come from a modal prompt; Delete confirms
# first (nav_delete).
proc nav_menu_fs {m type path} {
	if {$::nav_root eq ""} return
	set target [expr {$type eq "dir" ? $path : \
		($type eq "file" ? [file dirname $path] : $::nav_root)}]
	$m add separator
	$m add command -label "New File…"   -command [list nav_new $target file]
	$m add command -label "New Folder…" -command [list nav_new $target dir]
	if {$type ne "none"} {
		$m add command -label "Rename…" -command [list nav_rename $path]
		$m add command -label "Delete…" -command [list nav_delete $path]
	}
}
# Append the git items for a row, given its type and abspath. A file uses its XY from
# the stash (untracked -> Track; worktree-dirty -> Stage; staged -> Unstage); a dir
# that contains changes offers "Stage folder" (git add on the directory).
proc nav_menu_git {m type path} {
	if {![info exists ::nav_git]} return
	if {$type eq "dir"} {
		if {[nav_dir_status $::nav_git $path] ne ""} {
			$m add separator
			$m add command -label "Stage folder" -command [list do_git add $path]
		}
		return
	}
	if {![dict exists $::nav_git $path]} {
		# Not a change of its own — but git collapses a WHOLLY untracked directory into a
		# single `dir/` entry and reports nothing beneath it, so every file inside one is
		# invisible to status: the git pane has no row for it, and this menu would have no
		# item. The tree is the only place those files are named, and `git add` takes one
		# happily (git then de-collapses the folder and lists the rest individually), so
		# the file's own door belongs here.
		if {[nav_untracked_parent $::nav_git $path]} {
			$m add separator
			$m add command -label "Track (git add)" -command [list do_git add $path]
		}
		return                                    ;# otherwise clean / no repo — no git items
	}
	set xy [dict get $::nav_git $path]
	set x [string index $xy 0] ; set y [string index $xy 1]
	$m add separator
	if {$x eq "?"} {
		$m add command -label "Track (git add)" -command [list do_git add $path]
		return
	}
	if {$y ne " "} { $m add command -label "Stage"   -command [list do_git add $path] }
	if {$x ne " "} { $m add command -label "Unstage" -command [list do_git unstage $path] }
	# Discard, the same confirm-gated entry the git pane carries — this door too (D93), so
	# "undo my edits to this file" is reachable from wherever you are looking at the file.
	# TRACKED changes only: a new file (untracked "?", returned above, or a staged addition
	# "A") is removed rather than reverted, and this menu's own fs "Delete…" already removes
	# it — two "Delete…" entries in one menu would be the worse UI.
	if {$x ne "A"} {
		$m add separator
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm [nav_repo_rel $path] 0]
	}
}
# A tree row's abspath as git names it: repo-root-relative. The project root IS the repo
# root (D43), so this is the path porcelain would have printed — which keeps the discard
# confirm reading the same from both doors, instead of quoting a long absolute path.
proc nav_repo_rel {path} {
	set parts [lrange [file split $path] [llength [file split $::nav_root]] end]
	return [expr {[llength $parts] ? [file join {*}$parts] : [file tail $path]}]
}

# ---------------------------------------------------------------------------
# File-management actions (D48). The menu-facing procs (nav_new/nav_rename/
# nav_delete) collect the name via a modal prompt / confirm; the fs_apply_* procs
# do the core call, retarget any open buffers, and repaint — split out so the
# headless smoke can drive the effect without a real dialog (as note_app_focus was
# for D47). Each fs.* op resolves its path against the project root and emits
# fs.changed, but we refresh_dock directly too: the acting GUI shouldn't wait on the
# round-trip event to see its own change.
# ---------------------------------------------------------------------------
proc nav_new {dir type} {
	set what [expr {$type eq "dir" ? "folder" : "file"}]
	set name [name_prompt "New [string totitle $what]" "Name of new $what:" ""]
	if {$name eq ""} return
	fs_apply_create $dir $type $name
}
proc nav_rename {path} {
	set name [name_prompt "Rename" "Rename to:" [file tail $path]]
	if {$name eq "" || $name eq [file tail $path]} return
	fs_apply_rename $path $name
}
proc nav_delete {path} {
	set isdir [file isdirectory $path]
	set what [expr {$isdir ? "folder and everything in it" : "file"}]
	if {[tk_messageBox -icon warning -type yesno -default no -title "rio — delete" \
			-message "Delete this $what?\n\n[file tail $path]\n\nThis cannot be undone."] ne "yes"} {
		return
	}
	fs_apply_delete $path
}

# A single-line component name is required: non-empty, no path separator, not . or ..
# — so a prompt can only ever create/rename WITHIN the target directory (nested paths
# are a deliberate non-goal). Rejected names flash the header and change nothing.
proc nav_name_ok {name} {
	return [expr {$name ne "" && [llength [file split $name]] == 1 && $name ni {. ..}}]
}

# Create $name (a file or dir) inside $dir, then unfold $dir so the new entry is on screen
# before the repaint (a no-op when $dir is the root, which is always shown).
proc fs_apply_create {dir type name} {
	if {![nav_name_ok $name]} { nav_flash "invalid name" ; return }
	set resp [rio_call fs.create \
		[dict create path [file join $dir $name] type $type]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	if {$dir ne $::nav_root} { dict set ::nav_expanded $dir 1 }   ;# reveal the new entry (root is always shown)
	refresh_dock
}
proc fs_apply_rename {path newname} {
	if {![nav_name_ok $newname]} { nav_flash "invalid name" ; return }
	set to [file join [file dirname $path] $newname]
	set resp [rio_call fs.rename [dict create path $path to $to]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	retarget_buffers $path $to
	refresh_dock
}
proc fs_apply_delete {path} {
	set resp [rio_call fs.delete [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	close_buffers_under $path
	refresh_dock
}

# After a rename, repoint every open buffer at the old path (or under it, for a dir
# rename) to the new path — client-side (so the tab retitles via tab_name) AND in the
# core via buffer.setpath (so the buffer's next Save writes the NEW name, not the old).
proc retarget_buffers {old new} {
	set touched 0
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p eq ""} continue
		if {$p eq $old} {
			set np $new
		} elseif {[string match "$old/*" $p]} {
			set np "$new/[string range $p [expr {[string length $old] + 1}] end]"
		} else {
			continue
		}
		bufset $id path $np
		rio_call buffer.setpath [dict create buffer $id path $np]
		hl_refresh_buffer $id   ;# a new extension may mean a new highlighter (D112)
		set touched 1
	}
	if {$touched} refresh_all
}

# After a delete, close every open buffer at that path (or under it, for a dir). We
# clear the modified flag first so close_tab's discard prompt doesn't offer to save a
# file that no longer exists; close_tab reuses do_close's reactivation / group-collapse.
proc close_buffers_under {path} {
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p eq ""} continue
		if {$p eq $path || [string match "$path/*" $p]} {
			bufset $id modified 0
			close_tab $id
		}
	}
}

# Briefly show a message in the files-pane header, then restore the real header.
# The files sibling of git_flash — reuses the header rather than adding a status
# widget; the scheduled populate_nav repaints the true directory line.
proc nav_flash {text} {
	.pfiles.hdr.head configure -text $text
	after cancel populate_nav
	after 2000 populate_nav
}

# A modal single-line name prompt (New / Rename). rio's first custom modal input —
# existing dialogs are tk_messageBox / tk_chooseDirectory. Returns the entered string,
# or "" on Cancel/Escape/empty. Grab + tkwait make it synchronous like those helpers.
proc name_prompt {title label prefill} {
	set w .nameprompt
	catch {destroy $w}
	toplevel $w
	wm title $w $title
	wm transient $w .
	wm resizable $w 0 0
	set ::name_prompt_result ""
	label $w.l -text $label -anchor w
	entry $w.e -width 32
	ctx_bind_input $w.e   ;# (D115)
	$w.e insert 0 $prefill
	frame $w.b
	button $w.b.ok     -text OK     -width 8 -command [list name_prompt_done $w 1]
	button $w.b.cancel -text Cancel -width 8 -command [list name_prompt_done $w 0]
	pack $w.b.ok $w.b.cancel -side left -padx 4
	pack $w.l -side top -fill x -padx 8 -pady {8 2}
	pack $w.e -side top -fill x -padx 8
	pack $w.b -side top -pady 8
	bind $w.e <Return> [list name_prompt_done $w 1]
	bind $w   <Escape> [list name_prompt_done $w 0]
	wm protocol $w WM_DELETE_WINDOW [list name_prompt_done $w 0]
	# Centre over the main window, then grab focus for the modal wait.
	wm withdraw $w
	update idletasks
	set x [expr {[winfo rootx .] + ([winfo width .]  - [winfo reqwidth $w])  / 2}]
	set y [expr {[winfo rooty .] + ([winfo height .] - [winfo reqheight $w]) / 3}]
	wm geometry $w +$x+$y
	wm deiconify $w
	$w.e selection range 0 end
	focus $w.e
	grab $w
	tkwait window $w
	return $::name_prompt_result
}
proc name_prompt_done {w ok} {
	if {$ok} { set ::name_prompt_result [string trim [$w.e get]] } \
	else     { set ::name_prompt_result "" }
	catch {grab release $w}
	destroy $w
}

proc open_folder_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Open folder (remote)" dir]
	} else {
		set p [tk_chooseDirectory -title "Open folder"]
	}
	if {$p ne ""} { open_folder $p }
}

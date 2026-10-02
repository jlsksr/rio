# rio-gui/files.tcl — the Files pane and its file actions.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The file pane: a tree from the project root (D87), listed one directory per
# fs.list call; a directory unfolds in place. The core owns which folder is
# open: project.open, and the pane repaints on project.opened (D3).
#   ::nav_root       the project root (absolute)
#   ::nav_expanded   the unfolded directories, a dict used as a set
# A row's payload is {type abspath}.
#
#     ▾ src/
#   M     ▪ main.tcl
#     ▸ docs/
#   ?   ▪ notes.txt
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
	# Remember the folder for the next launch (D88). Local cores only: a
	# remote root is a path on the server.
	if {!$::core_remote} { set ::last_project $::nav_root ; prefs_save }
	refresh_dock
}

# Repaint the dock pane that is showing. rio does not watch the filesystem:
# it repaints when a folder opens, a file is saved, fs.changed arrives (D47),
# or rio regains OS focus.
proc refresh_dock {} {
	rio::panel::refresh $::dock_pane
}

# Repaint the files pane: at each level directories, then files; an unfolded
# directory's children indented below it. A row:
#   2 chars of git status (D43), two spaces per depth, a glyph (▸ folded,
#   ▾ unfolded, ▪ file), the name.
proc populate_nav {} {
	set b .pfiles.well.body
	rl_begin $b
	set ::nav_row_depth [dict create]   ;# path -> tree depth, for the arrow-click hit test (D87)
	# List the root once. If the folder is gone, the project closes: forget
	# it (D88) and show the placeholder. No dialog.
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

# List one directory and draw its level. An fs.list error is reported; the
# rows already drawn stay.
proc nav_render_level {dir depth git} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	nav_render_entries $dir $depth $git [dict get $resp result entries]
}

# Draw one listed level, directories first, and recurse into each unfolded
# directory. Its own proc, so the root's listing is not fetched twice.
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

# Are directory $d's children on screen? The root's and an unfolded
# directory's are. A change under one is worth a repaint (D47).
proc nav_dir_visible {d} {
	return [expr {$d eq $::nav_root || [dict exists $::nav_expanded $d]}]
}

# Apply ::show_hidden (dotfiles; off by default): repaint and save. The View
# menu, Preferences and the header glyph all come through here.
proc apply_show_hidden {} {
	nav_hidden_glyph
	populate_nav
	prefs_save
}
# The header glyph: ◉ when hidden files show, ◌ when not.
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

# The project's git status as a dict abspath -> XY (the two porcelain chars).
# Empty without a repo. git's paths are relative to the repo root, which is
# the project root (D43).
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
# A file's flag: the worktree char, else the staged one; "" when clean.
proc nav_file_status {git path} {
	if {![dict exists $git $path]} { return "" }
	set xy [dict get $git $path]
	set y [string index $xy 1]
	return [expr {$y ne " " ? $y : [string index $xy 0]}]
}
# A directory's flag: "·" when it is or contains a change, else "".
proc nav_dir_status {git path} {
	if {[dict exists $git $path]} { return "·" }
	foreach p [dict keys $git] {
		if {[string match "$path/*" $p]} { return "·" }
	}
	return ""
}
# Is `path` inside a directory git reports as untracked? git names such a
# directory once and nothing below it. Any ancestor up to the root counts.
proc nav_untracked_parent {git path} {
	for {set d [file dirname $path]} {$d ne [file dirname $d]} {set d [file dirname $d]} {
		if {[dict exists $git $d] && [string index [dict get $git $d] 0] eq "?"} { return 1 }
		if {$d eq $::nav_root} break
	}
	return 0
}

# Append one row: the status gutter (2 chars, in a fixed column), the indent,
# the glyph, the label. The payload is {type abspath}.
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

# Double-click or Enter on a row: fold or unfold a directory, open a file.
proc nav_open {payload} {
	lassign $payload type path
	switch -- $type {
		dir  { nav_toggle_expand $path }
		file { do_open $path }
	}
}
# Fold or unfold a directory and repaint. Folding keeps the state of the
# directories below it.
proc nav_toggle_expand {path} {
	if {[dict exists $::nav_expanded $path]} {
		dict unset ::nav_expanded $path
	} else {
		dict set ::nav_expanded $path 1
	}
	populate_nav
	session_save   ;# the unfolded set changed — record it so the next launch resumes it (D89)
}

# Clicks in the files pane (D87): a single click on a folder's arrow unfolds
# it; a double-click on a name activates.
#
# Is column `col` on a directory row's arrow? The name starts at column
# 2 (gutter) + 2·depth (indent) + 2 (glyph and space); left of that is the
# arrow. No pixels, so it can be tested.
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
# Double click: activate, unless it is on the arrow: the first click already
# toggled it.
proc nav_b1_double {w x y} {
	if {![llength $::rl_rows($w)]} return
	set row [rl_row_at $w $x $y]
	rl_select $w $row 0
	if {![nav_hit_arrow $w $row $x $y]} { rl_activate $w }
}

# Right-click a row: a menu of actions about that row. Rebuilt each time, so
# the git items match the row's status (D44). nav_menu_build fills the menu,
# so a headless test can read it without posting.
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
# The file-management entries (D48). New File and New Folder create inside a
# folder row's folder, or beside a file row. Rename and Delete act on the row.
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
# The git entries for a row. A file: Track if untracked, Stage if changed,
# Unstage if staged. A directory with changes: Stage folder.
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
		# A file inside an untracked directory has no status entry of its
		# own; the tree is the only place to track it from.
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
	# Discard Changes…, as in the git pane (D93). For tracked changes only: a
	# new file is removed by this menu's own Delete….
	if {$x ne "A"} {
		$m add separator
		$m add command -label "Discard Changes…" \
			-command [list git_discard_confirm [nav_repo_rel $path] 0]
	}
}
# A row's path as git names it: relative to the project root (D43).
proc nav_repo_rel {path} {
	set parts [lrange [file split $path] [llength [file split $::nav_root]] end]
	return [expr {[llength $parts] ? [file join {*}$parts] : [file tail $path]}]
}

# ---------------------------------------------------------------------------
# File-management actions (D48). nav_new, nav_rename and nav_delete ask for a
# name or a confirmation. The fs_apply_* procs call the core, fix the open
# buffers and repaint; a test calls those directly.
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

# Is `name` one path component? Not empty, no separator, not . or ..
proc nav_name_ok {name} {
	return [expr {$name ne "" && [llength [file split $name]] == 1 && $name ni {. ..}}]
}

# Create $name inside $dir and unfold $dir, so the new entry shows.
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

# After a rename: point every open buffer at or under the old path to the new
# one, here (the tab's title) and in the core (buffer.setpath: the next Save).
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

# After a delete: close every open buffer at or under the path. `modified` is
# cleared first, so nothing asks to save a file that is gone.
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

# Show a message in the pane's header for two seconds.
proc nav_flash {text} {
	.pfiles.hdr.head configure -text $text
	after cancel populate_nav
	after 2000 populate_nav
}

# A modal one-line prompt. Returns the text, or "" on Cancel, Escape or empty.
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

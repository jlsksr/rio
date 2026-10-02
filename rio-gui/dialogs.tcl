# rio-gui/dialogs.tcl — shared dialogs: pick lists, file browsing, About.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# The rows for the open-buffer picker (D74), used by "Compare With Another
# Tab…" and "Switch to Tab…": every group's tabs but `exclude`, as {id label}.
# The label is the tab name, its unsaved dot and its directory.
proc buffer_pick_rows {{exclude ""}} {
	set rows {}
	foreach g $::groups {
		foreach id [gorder $g] {
			if {$id eq $exclude} continue
			set label "[tab_name $id][tab_dot $id]"
			set p [bufget $id path]
			if {$p ne ""} { append label "    [file dirname $p]" }
			lappend rows [list $id $label]
		}
	}
	return $rows
}

# The list picker (D74, D92): pick one row. A row is {payload label}. Returns
# the chosen payload, or "" on cancel or an empty list.
# - Every list in rio that can grow without bound comes here, not to a menu:
#   a menu can post taller than the screen (CAVEATS.md); a listbox scrolls.
# - `initial` preselects the row with that payload.
# - Double-click or Return chooses; Escape cancels. Modal.
proc pick_dialog {title rows {initial ""}} {
	if {![llength $rows]} { bell ; return "" }   ;# nothing to pick — don't open an empty dialog

	set w .pick
	destroy $w
	toplevel $w
	wm title $w $title
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	set wide 0
	foreach r $rows { set wide [expr {max($wide, [string length [lindex $r 1]])}] }

	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.pick.body.list yview}
	listbox $w.body.list -activestyle none -exportselection 0 \
		-height [expr {max(6, min(16, [llength $rows]))}] \
		-width  [expr {max(28, min(72, $wide + 2))}] \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .pick.body.sb .pick.body.list}
	pack $w.body.list -side left -fill both -expand 1

	set ::pick_payloads {}
	set at 0
	foreach r $rows {
		if {[lindex $r 0] eq $initial} { set at [llength $::pick_payloads] }
		lappend ::pick_payloads [lindex $r 0]
		$w.body.list insert end [lindex $r 1]
	}
	$w.body.list selection set $at
	$w.body.list activate $at
	$w.body.list see $at

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ok     -text OK     -font RioUIFont -command pick_choose
	button $w.btns.cancel -text Cancel -font RioUIFont \
		-command {set ::pick_result "" ; destroy .pick}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3

	grid $w.body -row 0 -column 0 -sticky nsew -padx 8 -pady {8 4}
	grid $w.btns -row 1 -column 0 -sticky e    -padx 5 -pady {2 8}
	grid rowconfigure $w 0 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> pick_choose
	bind $w.body.list <Return>          pick_choose
	bind $w <Escape> {set ::pick_result "" ; destroy .pick}

	set ::pick_result ""
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
	return $::pick_result
}
# Resolve the listbox selection to its row payload and close the dialog.
proc pick_choose {} {
	set sel [.pick.body.list curselection]
	if {$sel eq ""} return
	set ::pick_result [lindex $::pick_payloads $sel]
	destroy .pick
}

# Show the buffer picker modally and return the chosen buffer id (or "" on cancel).
proc buffer_pick_dialog {title {exclude ""}} {
	return [pick_dialog $title [buffer_pick_rows $exclude]]
}

# View ▸ Switch to Tab… (D74): pick an open buffer and activate it.
proc switch_tab_dialog {} {
	set id [buffer_pick_dialog "Switch to tab"]
	if {$id ne ""} { activate $id }
}

# rio's build id for About (D76): `git describe --tags --always` in rio's own
# source dir. Version (D123) names the release; Build names the commit.
# "unknown" without git. Computed once, on first use.
proc rio_build_id {} {
	if {![info exists ::rio_build]} {
		if {[catch {exec git -C [file dirname $::rio_self] describe --tags --always} id]} {
			set ::rio_build "unknown"
		} else {
			set ::rio_build [string trim $id]
		}
	}
	return $::rio_build
}

# That commit's date, as "YYYY-MM-DD HH:MM". "unknown" without git.
proc rio_build_date {} {
	if {![info exists ::rio_build_date]} {
		if {[catch {exec git -C [file dirname $::rio_self] show -s --format=%cd \
			{--date=format:%Y-%m-%d %H:%M} HEAD} d]} {
			set ::rio_build_date "unknown"
		} else {
			set ::rio_build_date [string trim $d]
		}
	}
	return $::rio_build_date
}

# About's Version row (D123): this checkout's version, and the core's if it
# differs: "0.4.0 (core 0.3.0)".
proc about_version {} {
	if {$::core_version ne "" && $::core_version ne $rio::version} {
		return "$rio::version (core $::core_version)"
	}
	return $rio::version
}

# Help ▸ About rio (D76): name, description, and the rows Version, Build,
# Date, Protocol, License (D121). The licence name is a literal here;
# smoke.tcl holds it to LICENSE. One control, Close; Esc and Return close too.
proc about_dialog {} {
	set w .about
	destroy $w
	toplevel $w
	wm title $w "About rio"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set fam [font actual RioUIFont -family]
	# A muted tone: the foreground blended toward the background.
	set mute [blend_hex [dict get $c ui.fg] [dict get $c ui.bg] 45]

	label $w.name -text "rio" -font [list $fam 20 bold] \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	label $w.tag -font RioUIFont -justify left -wraplength 340 \
		-text "A small, cross-platform IDE, written from scratch in Tcl/Tk." \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# The facts, in two columns, muted: information, not controls.
	frame $w.facts -background [dict get $c ui.bg]
	set r 0
	foreach {k v} [list Version [about_version] Build [rio_build_id] \
		Date [rio_build_date] Protocol $::rio_protocol License "MIT"] {
		label $w.facts.k$r -text $k -font RioUIFont -anchor e \
			-background [dict get $c ui.bg] -foreground $mute
		label $w.facts.v$r -text $v -font RioUIFont -anchor w \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		grid $w.facts.k$r -row $r -column 0 -sticky e -padx {0 8}
		grid $w.facts.v$r -row $r -column 1 -sticky w
		incr r
	}
	button $w.ok -text "Close" -font RioUIFont -command {destroy .about}

	# rio's icon, left of the name: an image apply_window_icon already loaded
	# (D117). Without one, column 0 is simply empty.
	set icon ""
	foreach n {64 48 32} {
		if {[llength [info commands ::rio_icon_$n]]} { set icon ::rio_icon_$n ; break }
	}
	if {$icon ne ""} {
		label $w.icon -image $icon -background [dict get $c ui.bg] -borderwidth 0
		grid $w.icon -row 0 -column 0 -rowspan 3 -sticky n -padx {16 0} -pady {16 0}
	}

	grid $w.name  -row 0 -column 1 -sticky w  -padx 16 -pady {14 0}
	grid $w.tag   -row 1 -column 1 -sticky w  -padx 16 -pady {4 8}
	grid $w.facts -row 2 -column 1 -sticky w  -padx 16
	grid $w.ok    -row 3 -column 1 -sticky e  -padx 16 -pady {10 12}
	grid columnconfigure $w 1 -weight 1

	bind $w <Escape> {destroy .about}
	bind $w <Return> {destroy .about}
	catch {grab $w}
	focus $w.ok
}

# The remote file browser (D29, D30). With a remote core, Tk's own choosers
# would browse the client's disk. This one walks the core's tree with fs.list.
# A Location bar jumps to a typed path.
#
#   mode = open -> pick an existing file    -> returns its abs path
#          save -> pick a dir + type a name -> returns dir/name
#          dir  -> pick a directory         -> returns it
#
# Returns the chosen absolute path, or "" if cancelled.

# The rows for one remote directory: "../" (unless at a root), directories,
# files; each {type abspath display}. No widgets, so it can be tested.
proc rbrowse_rows_for {dir} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		return [dict create ok 0 error [dict get $resp error message]]
	}
	set abs [dict get $resp result path]   ;# the core's normalized dir
	set rows {}
	# A root is a path whose dirname is itself: "/" and "C:/" alike.
	if {[file dirname $abs] ne $abs} { lappend rows [list dir [file dirname $abs] "../"] }
	foreach grp {dir file} {
		foreach e [dict get $resp result entries] {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			lappend rows [list $grp [file join $abs $name] \
				[expr {$grp eq "dir" ? "$name/" : "  $name"}]]
		}
	}
	return [dict create ok 1 dir $abs rows $rows]
}

# Is $p absolute as the core sees it? Judged by shape: a leading "/" or an
# "X:" prefix. `file pathtype` and `file normalize` use the client's rules,
# which are wrong when client and core differ in platform.
proc core_path_absolute {p} {
	return [expr {[string match "/*" $p] || [regexp {^[A-Za-z]:[/\\]} $p]}]
}

# Where the browser opens: the seed's directory, else the project root, else
# the core's filesystem root (from session.hello).
proc rbrowse_start {seed} {
	if {$seed ne "" && [core_path_absolute $seed]} {
		return [file dirname $seed]
	}
	set root [dict get [rio_call project.get {}] result root]
	return [expr {$root ne "" ? $root : $::core_fsroot}]
}

# List $dir in the browser. In dir mode files are left out. A bad path beeps
# and the old listing stays.
proc rbrowse_go {dir} {
	set info [rbrowse_rows_for $dir]
	# The call ran the event loop: the dialog may be gone.
	if {![winfo exists .rbrowse.loc]} return
	if {![dict get $info ok]} { bell ; return }
	set ::rbrowse_dir [dict get $info dir]
	.rbrowse.loc delete 0 end
	.rbrowse.loc insert end $::rbrowse_dir
	.rbrowse.body.list delete 0 end
	set ::rbrowse_rows {}
	foreach row [dict get $info rows] {
		lassign $row type abs display
		if {$::rbrowse_mode eq "dir" && $type eq "file"} continue
		.rbrowse.body.list insert end $display
		lappend ::rbrowse_rows $row
	}
}

# Double-click / Enter a row: descend into a dir; on a file, choose it (open mode)
# or copy its name into the Name field (save mode).
proc rbrowse_activate {} {
	set sel [.rbrowse.body.list curselection]
	if {$sel eq ""} return
	lassign [lindex $::rbrowse_rows $sel] type abs display
	if {$type eq "dir"} { rbrowse_go $abs ; return }
	switch -- $::rbrowse_mode {
		open { set ::rbrowse_result $abs ; destroy .rbrowse }
		save { .rbrowse.name delete 0 end ; .rbrowse.name insert end [file tail $abs] }
	}
}

# The Choose button: a directory (dir mode), the shown dir + typed Name (save), or
# the selected file (open). An empty Name / no file selection just beeps.
proc rbrowse_choose {} {
	switch -- $::rbrowse_mode {
		dir {
			# The selected folder, else the folder shown.
			set sel [.rbrowse.body.list curselection]
			if {$sel ne ""} {
				set ::rbrowse_result [lindex [lindex $::rbrowse_rows $sel] 1]
			} else {
				set ::rbrowse_result $::rbrowse_dir
			}
		}
		save {
			set name [string trim [.rbrowse.name get]]
			if {$name eq ""} { bell ; return }
			set ::rbrowse_result [expr {[core_path_absolute $name] \
				? $name : [file join $::rbrowse_dir $name]}]
		}
		open {
			set sel [.rbrowse.body.list curselection]
			if {$sel eq ""} { bell ; return }
			lassign [lindex $::rbrowse_rows $sel] type abs display
			if {$type ne "file"} { bell ; return }
			set ::rbrowse_result $abs
		}
	}
	if {$::rbrowse_result ne ""} { destroy .rbrowse }
}

proc remote_browse_dialog {title mode {seed ""}} {
	set w .rbrowse
	destroy $w
	toplevel $w
	wm title $w $title
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Location bar — the current remote dir, editable to jump anywhere.
	label $w.loclbl -anchor w -font RioUIFont -text "Location:" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.loc -font RioUIFont -width 54
	ctx_bind_input $w.loc   ;# (D115)
	bind $w.loc <Return> { rbrowse_go [string trim [.rbrowse.loc get]] }

	# The listing (an auto-hiding scrollbar, like the dock file pane).
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.rbrowse.body.list yview}
	listbox $w.body.list -height 16 -width 54 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .rbrowse.body.sb .rbrowse.body.list}
	pack $w.body.list -side left -fill both -expand 1

	frame $w.btns -background [dict get $c ui.bg]
	set oklbl [dict get {open Open save {Save here} dir {Choose folder}} $mode]
	button $w.btns.ok     -text $oklbl -font RioUIFont -command rbrowse_choose
	button $w.btns.cancel -text Cancel -font RioUIFont \
		-command {set ::rbrowse_result "" ; destroy .rbrowse}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3

	grid $w.loclbl -row 0 -column 0 -sticky w    -padx 8 -pady {8 0}
	grid $w.loc    -row 1 -column 0 -sticky we   -padx 8
	grid $w.body   -row 2 -column 0 -sticky nsew -padx 8 -pady 4
	set btnrow 3
	if {$mode eq "save"} {
		label $w.namelbl -anchor w -font RioUIFont -text "Name:" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		entry $w.name -font RioUIFont -width 54
		ctx_bind_input $w.name   ;# (D115)
		$w.name insert end [file tail $seed]
		grid $w.namelbl -row 3 -column 0 -sticky w  -padx 8
		grid $w.name    -row 4 -column 0 -sticky we -padx 8
		set btnrow 5
	}
	grid $w.btns -row $btnrow -column 0 -sticky e -padx 5 -pady {2 8}
	grid rowconfigure $w 2 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> rbrowse_activate
	bind $w.body.list <Return>          rbrowse_activate
	bind $w <Escape> {set ::rbrowse_result "" ; destroy .rbrowse}

	set ::rbrowse_mode   $mode
	set ::rbrowse_result ""
	set ::rbrowse_rows   {}
	rbrowse_go [rbrowse_start $seed]

	# The dialog may have been cancelled during the first listing.
	if {[winfo exists $w]} {
		catch {grab $w}
		focus $w.body.list
		tkwait window $w
	}
	return $::rbrowse_result
}

# --- dialog wrappers ---------------------------------------------------------
# Each picks a path and calls a do_* action: Tk's chooser for a local core,
# the remote browser for a remote one.
proc open_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Open file (remote)" open]
		if {$p ne ""} { do_open $p }
		return
	}
	# -multiple 1: several files may be chosen; the last one ends up focused.
	foreach p [tk_getOpenFile -title "Open file" -multiple 1] {
		if {$p ne ""} { do_open $p }
	}
}
proc save_as_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Save as (remote)" save [bufget $::cur path]]
	} else {
		set p [tk_getSaveFile -title "Save as"]
	}
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
}

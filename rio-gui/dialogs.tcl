# rio-gui/dialogs.tcl — shared dialogs: pick lists, file browsing, About.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# The open-buffer picker (D74). One modal dialog (pick_dialog, below) serves both
# "Compare With Another Tab…" and View ▸ "Switch to Tab…" — each is just "pick an open
# buffer from a list". It replaces the old unbounded .m.tabs cascade (a menu could grow
# screen-tall on X11; a dialog is bounded and scrolls), and unlike the cascade it can
# show a path hint so two same-named tabs are told apart.
#
# The row list is built by a separate proc so it stays headless-testable the way
# tabs_menu_fill was directly callable: walk every group's tab order (the same source),
# skipping `exclude` (the current buffer, for compare). Each row is {id label}; the
# label is the tab name + unsaved dot, plus the parent directory as a dim hint when the
# buffer has a path.
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

# The bounded list picker — "pick one row from a list", the shape D74 introduced for
# buffers and D92 generalised. The dialog knows nothing about what a row *means*: each
# row is {payload label}, and the return is the chosen payload, or "" on cancel or an
# empty list. Modelled on remote_browse_dialog: themed toplevel, listbox + auto-hiding
# scrollbar, Double-click/Return choose, Escape/Cancel abort, grab + tkwait. It exists
# because a Tk menu has no size bound (an unbounded cascade can post taller than the
# screen and misbehave on X11, see CAVEATS.md) while a listbox scrolls inside a fixed
# frame — so every data-driven, unbounded list in rio comes here instead of to a menu.
#
# `initial` preselects the row carrying that payload (the theme in use, say) rather than
# row 0, so the dialog opens on the current value the way a Windows chooser does. The box
# is sized to its content within bounds — a 5-theme list isn't a 14-row well, and a long
# one still stops well short of the screen.
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

# View ▸ Switch to Tab… (D74): the bounded replacement for the old top-level Tabs menu —
# pick any open buffer and activate it (activate focuses the group that holds it).
proc switch_tab_dialog {} {
	set id [buffer_pick_dialog "Switch to tab"]
	if {$id ne ""} { activate $id }
}

# rio's own build identity for Help ▸ About rio (D76). This is NOT rio's version — that
# is $rio::version (D123), the row above it. The two answer different questions and both
# are worth showing: Version says which RELEASE LINE this is, Build says which exact
# COMMIT, and between releases Build is the precise one.
# `git describe --tags --always` gives the *tag* once one exists and the abbreviated commit
# otherwise, so at a release Build sharpens itself for free. Run against rio's OWN source dir
# ([file dirname $::rio_self], the normalized script path) — not the user's project, and not
# the core, which may be a different build on another machine. An installed copy with no git
# metadata (or no git) falls back to "unknown". Computed once and cached; About is rare, so
# there's no reason to shell out at startup.
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

# The date/time of that build's commit (committer date, local zone), so About can say not
# just which rio but when it was cut. Same source dir and same "unknown" fallback + caching
# as rio_build_id. --date=format gives a compact "YYYY-MM-DD HH:MM"; %cd honours it.
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

# What About's Version row says (D123). Normally just this checkout's release version —
# a spawned core is the same tree, so naming it twice would be noise. But a core reached
# over --connect (D29/D30) can be any build, and when it reports a DIFFERENT version that
# is precisely the fact a bug report needs, so the row carries it: "0.1.0 (core 0.1.1)".
# A core too old to report one leaves ::core_version empty and says nothing, which is the
# D19 fallback rather than a claim that the versions match.
proc about_version {} {
	if {$::core_version ne "" && $::core_version ne $rio::version} {
		return "$rio::version (core $::core_version)"
	}
	return $rio::version
}

# Help ▸ About rio (D76): a small themed modal with rio's name, one-line description, and the
# release version (D123), the build id, its commit date, the wire-protocol version (all handy
# in a bug report — see ::rio_protocol) and the licence (D121) — the one fact here that is
# about the copy in front of you rather than this build, and the reason it is legible without
# going back to the repository.
# The licence name is written here rather than read from LICENSE: the file need not sit beside a
# deployed GUI, and smoke.tcl holds this string to it. Info is
# static labels (muted), the lone control is Close; Esc/Return dismiss. Non-blocking (grab but
# no tkwait) — it just informs, it returns nothing.
#
# Version comes FIRST: it is the coarsest and most quotable fact, and the one a bug report
# leads with. It names the core too, but only when the core's differs (about_version) —
# a second permanent row would repeat the same number on every local run, since a spawned
# core is always this very tree.
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
	# No dedicated "muted" UI role in the theme vocabulary — blend the fg halfway toward the
	# bg for a dim label tone that reads on any theme (the restyle_group currentline pattern).
	set mute [blend_hex [dict get $c ui.fg] [dict get $c ui.bg] 45]

	label $w.name -text "rio" -font [list $fam 20 bold] \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	label $w.tag -font RioUIFont -justify left -wraplength 340 \
		-text "A small, cross-platform IDE, written from scratch in Tcl/Tk." \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# The static facts, as a dim two-column block so they read as info, not controls.
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

	# rio's own icon, to the left of the name — the Win2000/VSCode About-box shape. It
	# reuses an image apply_window_icon (D117) already loaded for `wm iconphoto`, so
	# nothing is read from disk here and the box always shows the icon rio is actually
	# wearing. The PNG's transparency composites over the label's themed background.
	#
	# Column 0 is the icon's, column 1 the text's, ALWAYS — so when there is no icon to
	# show (the D117 soft case: a checkout with icons/ removed) column 0 simply has no
	# width and the box keeps its old single-column look, with no second layout to hold
	# in step.
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

# A protocol-native remote file/folder browser (D29/D30). In remote mode
# the filesystem of record is the CORE's, but tk_getOpenFile / tk_getSaveFile /
# tk_chooseDirectory browse the CLIENT's disk — wrong for a remote core. So those
# choosers give way to this browser, which walks the REMOTE tree over `fs.list` —
# the very op the docked file pane uses (populate_nav) — point-and-click, not typed.
# An editable Location bar still lets you jump straight to a known path, so it also
# subsumes the old typed-path prompt (remote_path_dialog).
#
#   mode = open -> pick an existing file    -> returns its abs path
#          save -> pick a dir + type a name -> returns dir/name
#          dir  -> pick a directory         -> returns the shown dir
#
# Returns the chosen absolute path, or "" if cancelled.

# The row model for one remote directory: a ".." row (unless at "/"), then dirs,
# then files — each {type abspath display}, already dictionary-sorted by the core.
# Split out from the widget code so the fs.list walk is testable headlessly.
proc rbrowse_rows_for {dir} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		return [dict create ok 0 error [dict get $resp error message]]
	}
	set abs [dict get $resp result path]   ;# the core's normalized dir
	set rows {}
	# At a filesystem root there is no parent to offer. Asking whether the dirname is
	# the path itself, rather than testing `$abs ne "/"`, is what makes this right off
	# POSIX: a Windows root is "C:/", whose dirname is itself, so the literal put a
	# "../" row there that navigated straight back to the same directory. $abs is the
	# CORE's normalized path, so this holds for a remote core too.
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

# Is $p absolute AS THE CORE SEES IT? `file pathtype` answers with the CLIENT's rules,
# which is wrong the moment the two platforms differ: a Windows client calls the Linux
# core's "/home/jka" *volumerelative*, not absolute — so a remote path typed into the
# browser was treated as relative and joined onto the current directory, and a remote
# seed never opened in its own folder. Judge by shape instead — a leading "/" (POSIX,
# and UNC as "//") or an "X:" drive prefix — which reads correctly for either core from
# either client. Deliberately NOT [file normalize]: on a Windows client that rewrites a
# core path like "/home/jka" to "C:/home/jka".
proc core_path_absolute {p} {
	return [expr {[string match "/*" $p] || [regexp {^[A-Za-z]:[/\\]} $p]}]
}

# Where the browser opens: the seed's directory if it names an absolute path, else
# the open project's root, else the CORE's filesystem root — which the core told us at
# session.hello rather than the GUI assuming "/" (right for a POSIX core, unlistable on
# a Windows one). The Location bar reaches anywhere from there.
proc rbrowse_start {seed} {
	if {$seed ne "" && [core_path_absolute $seed]} {
		return [file dirname $seed]
	}
	set root [dict get [rio_call project.get {}] result root]
	return [expr {$root ne "" ? $root : $::core_fsroot}]
}

# Re-list $dir into the browser: fill the Location bar and the listbox from
# rbrowse_rows_for, dropping files in dir mode. A bad path just beeps (the old
# listing stays), so a mistyped Location can't strand the dialog.
proc rbrowse_go {dir} {
	set info [rbrowse_rows_for $dir]
	# rbrowse_rows_for pumps the event loop (an fs.list round-trip). If the dialog was
	# cancelled meanwhile — Escape, WM close, a slow remote listing the user gave up on
	# — its widgets are gone; bail rather than crash on a stale ".rbrowse.loc".
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
			# Open the HIGHLIGHTED folder if a row is selected — the intuitive "click a folder,
			# press Open" that a bare tk_chooseDirectory denies (it returns only the folder you
			# have entered, not the one clicked). With nothing selected, fall back to the folder
			# currently shown, so you can still open a folder by navigating into it. In dir mode
			# only dirs and the "../" parent are listed, so a selection is always a directory.
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

	# The first rbrowse_go may have been cancelled mid-flight (an Escape during its
	# fs.list), taking the dialog with it — only grab/focus/wait if it's still here.
	if {[winfo exists $w]} {
		catch {grab $w}
		focus $w.body.list
		tkwait window $w
	}
	return $::rbrowse_result
}

# --- dialog wrappers ---------------------------------------------------------
# Each picks a path then calls a do_* action. The native chooser browses the local
# disk; when the core is remote (its FS isn't ours) it gives way to the remote file
# browser (remote_browse_dialog), which walks the server's tree over fs.list.
proc open_dialog {} {
	if {$::core_remote} {
		# The remote browser is a single-select tree (fs.list, one pick); open just it.
		set p [remote_browse_dialog "Open file (remote)" open]
		if {$p ne ""} { do_open $p }
		return
	}
	# -multiple 1 lets the native chooser Ctrl/Shift-select several files; the result
	# is then a LIST of paths (empty on cancel). Open each in order — do_open dedups
	# and activates, so the last selected file ends up focused.
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

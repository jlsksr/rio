#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (D1), a thin view (D3). It never edits its own
# text widget:
#
#   key ──► buffer.replace ──► core ──► buffer.changed ──► the widget changes
#
# - Always a client of a core over a channel (D30): a private core spawned on
#   a pipe, or with --connect a listening core on a socket. One code path.
# - The core owns the buffers. The frontend keeps the view state: tab order,
#   the active tab, each buffer's cursor and viewport (D22).
# - The text widget's command is renamed and proxied: Tk's bindings still
#   call `.t insert` and `.t delete`, and the proxy turns them into requests.
#   So every key, paste and cut take the same path.
#
# Run:  wish rio-gui.tcl [file ...]

# The hard dependencies, through the gate (D116). Tk by plain `require`:
# without Tk there is no dialog to draw. json by `gui_require`, which also
# shows a message box.
source [file join [file dirname [info script]] .. rio-core deps.tcl]
rio::deps::require Tk
rio::deps::gui_require json

# OS file-drop (D86) needs tkdnd, which is optional: without it rio runs the
# same, minus drag-to-open. Dragging a tab inside rio needs no extension.
set ::have_tkdnd [expr {![catch {package require tkdnd}]}]

# Under RIO_GUI_HEADLESS the window is withdrawn here, first thing (D127):
# the first entry into the event loop maps `.`, and boot enters it at every
# blocking op call. The block at the foot of this file gives the window its
# size. See CAVEATS.md.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }

# ---------------------------------------------------------------------------
# Transport (D30). The GUI never embeds the core.
#   default        spawn a private core and talk over its stdio pipe. Its
#                  filesystem is ours. No listening socket.
#   --connect h:p  attach to a listening core over TCP (D29). Its filesystem
#                  may be elsewhere, so paths are the server's (::core_remote).
# A test may pre-set ::connect_to to attach to an in-process server.
# ---------------------------------------------------------------------------
# The UTF-8 source guard (D54). Tcl 8.6 reads a script in the system
# encoding, cp1252 on Windows, and every non-ASCII literal would be garbled.
# Setting the encoding covers the files sourced below; this file was already
# read, so it is read again once. Nothing has run before this point.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

set ::rio_dir [file dirname [info script]]
set ::rio_self [file normalize [info script]]   ;# this script, for spawning a new window
source [file join $::rio_dir .. rio-core wire.tcl]
source [file join $::rio_dir .. rio-core conf.tcl]  ;# repository manifests are conf DATA (D21/D39)
source [file join $::rio_dir .. rio-core version.tcl] ;# rio::version — ONE literal, shared (D123)

set ::core_endpoint "" ;# host:port when attached to a daemon (remote); "" when local (D30)
set ::last_connect  "" ;# last host:port typed into "Connect to Remote Core…" (dialog seed)

# --version: print and exit, before a window opens or a core is spawned.
if {[lsearch -exact $argv --version] >= 0} {
	puts "rio $rio::version"
	exit 0
}

if {![info exists ::connect_to]} { set ::connect_to "" }
set ci [lsearch -exact $argv --connect]
if {$ci >= 0} {
	set ::connect_to [lindex $argv [expr {$ci + 1}]]
	set argv [lreplace $argv $ci [expr {$ci + 1}]]   ;# don't treat it as a file arg
}
if {$::connect_to eq "" && [info exists ::env(RIO_CONNECT)]} {
	set ::connect_to $::env(RIO_CONNECT)
}

set ::reply_seq 0
if {$::connect_to ne ""} {
	# Attach to a listening core (daemon mode). Its filesystem may not be ours.
	set ::core_remote 1
	lassign [split $::connect_to :] host port
	if {$host eq "" || ![string is integer -strict $port]} {
		puts stderr "rio-gui: --connect expects host:port, got '$::connect_to'"
		exit 2
	}
	# No stack trace for a failed connect: say what to check.
	if {[catch {socket $host $port} ::core_chan]} {
		puts stderr "rio-gui: cannot reach a rio core at $::connect_to ($::core_chan)."
		puts stderr "  • Is a core listening there?     tclsh rio-core/server.tcl $port"
		puts stderr "  • If it's remote, tunnel first:  ssh -L $port:127.0.0.1:$port <server>"
		exit 1
	}
	set ::core_endpoint $::connect_to
	set ::last_connect  $::connect_to
} else {
	# Default: spawn a private core on a pipe (D30). It needs a tclsh: from
	# PATH, else the one beside this wish.
	set ::core_remote 0
	set _tclsh [lindex [auto_execok tclsh] 0]
	if {$_tclsh eq ""} {
		set _me [info nameofexecutable]
		set _g [file join [file dirname $_me] [string map {wish tclsh} [file tail $_me]]]
		set _tclsh [expr {[file executable $_g] ? $_g : "tclsh"}]
	}
	set ::core_cmd [list $_tclsh [file join $::rio_dir .. rio-core server.tcl] --stdio]
	if {[catch {open |$::core_cmd r+} ::core_chan]} {
		puts stderr "rio-gui: could not start a local core ($::core_chan)."
		exit 1
	}
}
fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
fileevent $::core_chan readable core_reader

# The parts, one file per concern (ADR-0145). Order matters only for top-level code:
# state.tcl first, since the rest read it; build.tcl and menubar.tcl last, since
# they call into everything above. A part needs no D54 guard: the one above set
# the system encoding before any of them is read.
foreach _m {
	state layout link buffers tabs editor files git chat views dialogs help
	agent prompt find theme highlight prefs keymap repos install extensions
	trust menus widgets build menubar
} {
	source [file join $::rio_dir $_m.tcl]
}
unset _m

# The editor keyboard shortcuts and the edit-proxy are installed per group by
# make_editor_group (editor_bindings + editor_proxy). Only the window-manager close
# needs binding here.
wm protocol . WM_DELETE_WINDOW do_quit
# macOS's Quit (Cmd-Q, the application menu) goes to ::tk::mac::Quit. Without
# that proc Tk exits at once, skipping the unsaved-changes question (D134).
if {[tk windowingsystem] eq "aqua"} {
	proc ::tk::mac::Quit {} { do_quit }
	# The application menu's Preferences… and About (D136): Tk greys the
	# first and shows a generic panel for the second unless these exist.
	proc ::tk::mac::ShowPreferences {} { preferences_window }
	proc ::tkAboutDialog {} { about_dialog }
}

# The window and taskbar icon (D117).
# - PNG files, not a glyph: the window manager takes pixels. D27's glyph rule
#   is for rio's own UI.
# - Optional: a missing file leaves the window manager's default.
# - Every size is handed over and the WM picks. `-default` covers every
#   toplevel made later.
# - The sizes are a variable so smoke.tcl can check them (ADR-0117).
#   `icons/make-icons.sh` cuts this set.
set ::icon_sizes {16 24 32 48 64 128 256}
# The order to hand the images over in. macOS (D134) uses only the first
# image, as the Dock icon:
#   inside rio.app   none: the bundle's rio.icns has every size
#   elsewhere        the largest first
# Other platforms get the list as it came.
proc window_icon_order {imgs ws exe} {
	if {$ws ne "aqua"} { return $imgs }
	set res [file join [file dirname [file dirname $exe]] Resources rio.icns]
	if {[string match *.app/Contents/MacOS/* $exe] && [file exists $res]} { return {} }
	return [lreverse $imgs]
}
proc apply_window_icon {} {
	set dir [file join $::rio_dir icons]
	set imgs {}
	foreach n $::icon_sizes {
		set f [file join $dir rio-$n.png]
		if {![file exists $f]} continue
		if {[catch {image create photo ::rio_icon_$n -file $f}]} continue
		lappend imgs ::rio_icon_$n
	}
	set imgs [window_icon_order $imgs [tk windowingsystem] [info nameofexecutable]]
	if {[llength $imgs]} { catch {wm iconphoto . -default {*}$imgs} }
	# Windows: the taskbar and alt-tab render a real .ico best.
	if {[tk windowingsystem] eq "win32"} {
		set ico [file join $dir rio.ico]
		if {[file exists $ico]} { catch {wm iconbitmap . -default $ico} }
	}
}
apply_window_icon

# Re-sync the dock when rio regains OS focus, for changes made outside rio
# (app_focus_event). A focus event on any descendant reaches this binding.
bind . <FocusIn>  app_focus_event
bind . <FocusOut> app_focus_event

# The highlighters (D32), before the first apply_theme and the first buffer.
hl_load

# The editing modes (D38), before prefs so a saved mode name resolves.
modes_load
modes_menu_fill

# Saved preferences over the defaults, then the theme, before the first tab
# is drawn. A saved theme that is gone falls back to the default (D31).
prefs_load
ledger_load   ;# which extensions this GUI installed, with their provenance (D39)
ext_installed_compute  ;# the installed view (D107) — the core's half arrives with the first scan
sources_seed_default   ;# first run: pre-fill sources.list with rio's own repo (D39)
repo_keys_load         ;# which signing key speaks for which repository (D118)
# Greet the core before any other op, with a timeout: a dead `ssh -L` forward
# accepts the socket and never answers. On failure: a dialog, then exit.
hello_core 1
# The watchdog (D37) covers the rest of the session. Sockets only: a pipe
# reports EOF by itself.
if {$::core_remote} watch_start
set _boot_theme [rio_call theme.get [dict create name $::theme_name]]
if {![dict get $_boot_theme ok]} {
	set ::theme_name default
	set _boot_theme [rio_call theme.get {}]
}
apply_theme [dict get $_boot_theme result]
set ::theme_choice $::theme_name
# The Preferences window's Theme button (D58, D92) shows the current theme's
# label and "…". A trace keeps that text in step with ::theme_choice.
proc theme_choice_display {} { return "[theme_label $::theme_choice]…" }
set ::theme_choice_label [theme_choice_display]
trace add variable ::theme_choice write \
	{apply {{a b c} {set ::theme_choice_label [theme_choice_display]}}}

# Adopt the core's buffers, then the command line. Local: a directory opens
# as the project, a file in a tab. Remote: the path is on the server and
# cannot be tested from here, so each opens as a project (D29).
set ::nav_root ""          ;# rl_* list state was initialised at widget construction
set ::nav_expanded [dict create]   ;# unfolded-dir set for the files tree (D87)
set ::nav_row_depth [dict create]  ;# path -> depth, filled per paint (arrow-click hit test)
adopt_initial_buffers      ;# take over the core's existing buffer(s) (D29)
apply_layout               ;# derive placement + tab strips from the layout (D35 b/c)
rio::panel::refresh $::dock_pane   ;# first populate of the dock's active pane
apply_wrap                 ;# sync wrap + the horizontal scrollbar to ::wrap_lines
apply_wrap_indent          ;# size the wrapped-line indents to each buffer (if enabled)
apply_line_numbers         ;# grid each group's gutter to ::line_numbers (default on)
apply_curline              ;# paint the caret-line band on each group (default on)
nav_hidden_glyph           ;# sync the Files-pane ◉/◌ toggle to ::show_hidden (D62)
apply_editmode             ;# attach the editing mode (windows default) to the RioMode tag (D38)
adopt_agent_status         ;# mirror the core's live provider/auto-accept; don't overwrite it (D30)
foreach f $argv {
	if {$::core_remote} {
		open_folder $f
	} elseif {[file isdirectory $f]} {
		open_folder $f
	} else {
		do_open $f
	}
}

# A bare `rio` reopens the last project (D88). Local cores only.
reopen_last_project

# Reopen the files that were open last time (D31). ::rio_started is still 0,
# so these opens do not each save the session.
session_restore

# Let the window take its natural size, then stop the children from driving
# it: a sash drag then resizes the editor, not the window.
update idletasks
pack propagate . 0

# Startup is done: from here, view-state and workspace changes persist (D31).
set ::rio_started 1

# Ask once about every recovery copy of the files just reopened (D132).
recover_flush

# Check the installed extensions for new versions, if the user turned that
# on (D107). After ::rio_started, so "don't check again" is saved.
ext_check_arm

# The whole window is an OS file-drop target (D86). Each editor widget also
# registers itself (make_editor_group). Needs tkdnd and a local core.
if {$::have_tkdnd && !$::core_remote} {
	tkdnd::drop_target register . DND_Files
	bind . <<Drop>> {dnd_open_files %D}
}

# A headless window still needs a real size, or a test that asks whether
# something fits its pane measures nothing. So map it once, off-screen, and
# withdraw it again (D127, CAVEATS.md).
# - The map is needed: Windows never sizes an unmapped toplevel, and on X11 a
#   panedwindow lays out its panes only once mapped. Only a full `update` maps.
# - `wm overrideredirect . 1` keeps the window manager out, so it cannot give
#   the window the focus. Otherwise a keystroke at the display lands in the
#   boot buffer.
if {[info exists ::env(RIO_GUI_HEADLESS)]} {
	wm overrideredirect . 1      ;# the WM never manages it, so it cannot be given the focus
	wm geometry . 1200x800-4000-4000
	wm deiconify .
	update                       ;# a full update: idletasks alone does not MAP it
	wm withdraw .
	# Not on Aqua: clearing the flag there makes every later `update` spin
	# forever (Tk 8.6.16). A headless run never shows `.` again anyway.
	if {[tk windowingsystem] ne "aqua"} { wm overrideredirect . 0 }
}

# The check for the above: record here, fail the run at exit.
# `focus -displayof .` is non-empty only when the X input focus belongs to
# this process, and then real input can reach the run. Once, at boot, before
# a suite builds a toplevel of its own. Not on Windows, where the window
# manager does manage the map above.
set ::headless_focus {}
if {[info exists ::env(RIO_GUI_HEADLESS)] && $::tcl_platform(platform) ne "windows"} {
	set ::headless_focus [focus -displayof .]
}

# A headless run has no human at the display, so it must never ask one. Each
# blocking Tk dialog is replaced: it prints what it was about to ask to
# stderr and raises, which fails the suite that reached it.
# - An error report fails the run too: an op failed where the test did not
#   expect it.
# - A suite that means to exercise a dialog renames this guard and stubs it.
# - Not covered: rio's own tkwait-window modals (name_prompt, pick_dialog,
#   remote_browse_dialog, connect_remote_dialog, extw_sources_dialog,
#   keybindings_dialog). Each is reached only by an explicit call.
set ::headless_dialogs {}   ;# what was asked, when nobody was there to answer
if {[info exists ::env(RIO_GUI_HEADLESS)]} {
	foreach _hl_dlg {tk_messageBox tk_getOpenFile tk_getSaveFile tk_chooseDirectory
	                 tk_chooseColor tk_dialog} {
		if {[info commands ::$_hl_dlg] eq ""} continue
		rename ::$_hl_dlg ::_headless_real_$_hl_dlg
		proc ::$_hl_dlg {args} [string map [list @N@ $_hl_dlg] {
			lappend ::headless_dialogs "@N@ $args"
			puts stderr "HEADLESS DIALOG: @N@ $args"
			flush stderr
			return -code error "@N@ reached with no stub under RIO_GUI_HEADLESS: $args"
		}]
	}
	unset -nocomplain _hl_dlg

	# Raising is not enough: an error in a timer or event callback goes to the
	# background handler and the suite carries on. So `exit` checks the
	# recorded list: a run that asked anything fails.
	rename exit _headless_real_exit
	proc exit {{code 0}} {
		if {[llength $::headless_dialogs]} {
			puts stderr "\nRUN FAILED — [llength $::headless_dialogs] dialog(s) reached with no stub; a headless run must never ask:"
			foreach d $::headless_dialogs { puts stderr "  $d" }
			flush stderr
			if {$code == 0} { set code 1 }
		}
		if {$::headless_focus ne ""} {
			puts stderr "\nRUN FAILED — this run held the X input focus at boot (at $::headless_focus); a headless window must never be mapped on X11, or a keystroke at the display lands in the buffer (D127)."
			flush stderr
			if {$code == 0} { set code 1 }
		}
		_headless_real_exit $code
	}

	# wish's background-error handler is a dialog too. Print instead.
	proc bgerror {msg} {
		puts stderr "HEADLESS BGERROR: $msg\n$::errorInfo"
		flush stderr
	}
}

# Report the keys.json entries that could not be used, once.
if {[llength $::keymap_bad] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
	report_error "Some shortcuts in [keys_path] were ignored:\n  • [join $::keymap_bad "\n  • "]"
}

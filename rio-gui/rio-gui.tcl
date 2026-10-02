#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops, undo/redo through edit.*, and buffers (tabs) through buffer.new /
# buffer.close. The frontend is ALWAYS a client to a core at the far end of a
# channel (D30): by default it spawns a private core as a child and talks over its
# stdio pipe; --connect attaches to a listening core over a socket. There is no
# in-process path — local and remote are the same code — so the only way text
# appears on screen is the core's own change event, arriving over the channel.
#
# Multi-buffer: the core owns the buffers (D3); the frontend keeps the per-buffer
# *view* state — tab order, which one is active, and each buffer's cursor/viewport
# (frontend-local per D22). One text widget shows the active buffer; switching
# tabs swaps its contents and restores that buffer's cursor.
#
# The view stays dumb robustly by RENAMING the real text-widget command and
# proxying it: Tk's class bindings still call `.t insert`/`.t delete`, the proxy
# turns those into protocol requests and suppresses the local edit. The character
# arrives as a proper Tcl argument, so every key — brackets, quotes, backslashes,
# braces — is handled identically, and paste/cut come along for free.
#
# Run:  wish rio-gui.tcl [file ...]

# The hard dependencies, through the gate that reports a missing one as a sentence
# rather than a stack trace (D116) — on Windows an uncaught one is a modal dialog
# nobody can read past. Tk goes through the plain `require`: if Tk is what's missing
# there is nothing to draw a dialog with, so stderr is all there is. json (tcllib)
# then goes through `gui_require`, which also puts it in a message box — under wish
# on Windows stderr has no console to land in.
source [file join [file dirname [info script]] .. rio-core deps.tcl]
rio::deps::require Tk
rio::deps::gui_require json

# OS file-drop (D86): plain Tk cannot receive a drop from the OS file manager — that
# capability lives only in the external tkdnd extension. Load it OPTIONALLY: where it is
# installed, dragging a file onto the window opens it (drop targets registered further
# down); where it is absent, rio-gui runs exactly as before, just without drag-to-open, so
# the hard dependency bar stays Tk + json. (The "pure Tk, no tkdnd" note for INTERNAL tab
# dragging still holds — that gesture needs no extension; OS file-drop is the one that does.)
set ::have_tkdnd [expr {![catch {package require tkdnd}]}]

# A test harness sets RIO_GUI_HEADLESS to keep the window off the screen, and the window
# has to go off it HERE, first thing (D127). Nothing below maps `.` on purpose — the FIRST
# ENTRY INTO THE EVENT LOOP does, wherever it happens to be, and boot is full of them: every
# blocking op call vwaits on its reply (the one at the top of this file), and that is enough
# for Tk to map the toplevel. Withdrawing it before there is anything to map is the only
# placement that covers all of them; the sizing block at the far end of this file deals with
# the geometry a withdrawn window still needs. See CAVEATS.md.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }

# ---------------------------------------------------------------------------
# Transport (D30): the GUI is ALWAYS a client to a core at the far end of
# a channel — it never embeds the core. Two channel kinds, one client code path:
#   default        spawn a private core as a child and talk over its stdio pipe.
#                  Local: its filesystem is ours, and its agent runs as us (D30).
#                  No listening socket ⇒ nothing on a shared host to connect to.
#   --connect h:p  attach to a listening core over TCP — the optional daemon mode
#                  (D29). Its filesystem may be elsewhere (e.g. SSH-forwarded), so
#                  file access goes through typed server-side paths (::core_remote).
# A test may pre-set ::connect_to (a host:port) to attach to an in-process server.
# Only the wire encoder is sourced here (Tk-free); the core lives in its own process.
# ---------------------------------------------------------------------------
# rio's sources are UTF-8, but Tcl 8.6 decodes a script with the SYSTEM encoding —
# cp1252 on a Western Windows install — so every non-ASCII literal, and with it the
# whole D27 glyph vocabulary, arrives mojibake ("rio - untitled" renders as
# "rio â€" untitled"). Setting the system encoding fixes every file sourced BELOW,
# but this file's own literals were decoded before line 1 ran, so re-read it once.
# The guard is the first executable statement: nothing has run yet, so re-sourcing
# repeats nothing. No-op where the system encoding is already UTF-8 (Linux, the
# BSDs, and Tcl 9 everywhere).
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

# --version, before anything opens a window or spawns a core: a packager and a bug
# report both want the number without launching a GUI. The core answers the same flag
# (server.tcl), and both print the one literal above.
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
	# A failed connect must not dump a Tcl stack trace: usually the core isn't running,
	# or — for a remote daemon, loopback-bound (D29) — there's no SSH tunnel yet.
	if {[catch {socket $host $port} ::core_chan]} {
		puts stderr "rio-gui: cannot reach a rio core at $::connect_to ($::core_chan)."
		puts stderr "  • Is a core listening there?     tclsh rio-core/server.tcl $port"
		puts stderr "  • If it's remote, tunnel first:  ssh -L $port:127.0.0.1:$port <server>"
		exit 1
	}
	set ::core_endpoint $::connect_to
	set ::last_connect  $::connect_to
} else {
	# Default: spawn a private local core and talk over its stdio (D30). We run under
	# wish, so find a Tk-free tclsh — in PATH, else one beside our own interpreter.
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
# macOS's Quit (Cmd-Q, the application menu, logging out) is not the close button: Tk
# routes it to ::tk::mac::Quit, and with no such proc calls Tcl_Exit(0) directly —
# skipping the unsaved-changes question above (D134). Defined only under Aqua, where
# Tk looks for it; do_quit returning (a Cancel) leaves rio running, as it should.
if {[tk windowingsystem] eq "aqua"} {
	proc ::tk::mac::Quit {} { do_quit }
	# The rest of that application menu (D136). Tk greys rio ▸ Preferences… (⌘,) until
	# ::tk::mac::ShowPreferences exists, and rio ▸ About rio shows macOS's generic panel
	# unless a `tkAboutDialog` command does (tkMacOSXMenus.c). Both are rio's own windows.
	proc ::tk::mac::ShowPreferences {} { preferences_window }
	proc ::tkAboutDialog {} { about_dialog }
}

# The window / taskbar icon (D117). Without one the window manager and the
# taskbar each fall back to their OWN default, so rio showed two different generic
# icons in the two places.
#
# A RASTER asset, deliberately outside D27's monochrome-Unicode rule: that rule governs
# glyphs drawn INSIDE rio's own UI, where a font is the right tool. `_NET_WM_ICON` takes
# pixels, and a glyph would have to be rendered to a pixmap to get here anyway.
#
# SOFT, like tkdnd (D86): missing or unreadable files leave rio running exactly as
# before, with the window manager's default. The icons are only ever read, never
# required — so a checkout with the directory removed still starts.
#
# Tk 8.6 reads PNG natively, so this costs no dependency. Several sizes are handed over
# at once and the WM picks the one it wants (16 for the title bar, 32/48 for alt-tab,
# larger for the window list). `-default` also covers every toplevel made LATER, so the
# dialogs and the help window inherit it without each repeating this.
#
# The sizes are a VARIABLE, not a literal in the loop, so the guard in smoke.tcl can ask
# what was asked for rather than reading this proc's source text (ADR-0117: assert
# against behaviour). `icons/make-icons.sh` cuts exactly this set.
set ::icon_sizes {16 24 32 48 64 128 256}
# macOS (D134) is the exception to "the WM picks". Tk's Aqua `wm iconphoto` uses ONLY
# THE FIRST image and makes it the Dock icon (tkMacOSXWm.c says so), so handing it the
# set smallest-first put the 16px PNG, stretched, in the Dock. Two rules:
#   * inside rio.app, pass nothing — the bundle's rio.icns carries every size and macOS
#     picks the right one; any photo would only replace it with a single, fixed one.
#     (It must be rio.icns: a wish run from a terminal may itself live in Wish.app,
#     whose Resources hold Wish's icon, and that one rio does want to cover.)
#   * anywhere else, the LARGEST first, since that one image is scaled to Dock size.
# Other platforms get the list as it came. Pure, so smoke.tcl tests it without a Mac.
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
	# Windows only: `wm iconphoto` works there, but a real .ico is what the taskbar and
	# alt-tab render best. Harmless to attempt and caught if the file isn't there.
	if {[tk windowingsystem] eq "win32"} {
		set ico [file join $dir rio.ico]
		if {[file exists $ico]} { catch {wm iconbitmap . -default $ico} }
	}
}
apply_window_icon

# Re-sync the dock whenever rio regains OS focus, to pick up changes made outside rio
# (see app_focus_event). The binding lives on the toplevel bindtag, so a focus event on
# any descendant reaches it; app_focus_settle debounces the flurry into one check.
bind . <FocusIn>  app_focus_event
bind . <FocusOut> app_focus_event

# Load the syntax highlighters before the first apply_theme (which configures a
# text tag per token type from the theme's syntax.* roles) and before any buffer
# loads (which re-tokenises it) — D32.
hl_load

# Load the editing modes the same way (D38): registry, shipped modules, user
# drop-ins. Loaded before prefs so a persisted mode name can resolve; attached by
# apply_editmode in the boot applier block below.
modes_load
modes_menu_fill

# Load saved preferences (theme, wrap, dock, chat) over the defaults, then apply the
# theme before the first tab is drawn, so every widget — and the tab bar refresh_tabs
# builds — uses the role table. A persisted theme that no longer exists falls back to
# the default rather than erroring at startup (D31).
prefs_load
ledger_load   ;# which extensions this GUI installed, with their provenance (D39)
ext_installed_compute  ;# the installed view (D107) — the core's half arrives with the first scan
sources_seed_default   ;# first run: pre-fill sources.list with rio's own repo (D39)
repo_keys_load         ;# which signing key speaks for which repository (D118)
# Greet the core before any other op. This is the first exchange over the channel, so
# it's also where a stale connection surfaces: a dead `ssh -L` forward accepts the
# socket but never answers, and without this bounded handshake the GUI would hang with
# a blank window (a real bug report). fatal → a clear dialog, then exit.
hello_core 1
# The greeting bounded only the first exchange; the watchdog (D37) extends that
# cover to the whole session. Socket-attached cores only — a pipe EOFs on its own.
if {$::core_remote} watch_start
set _boot_theme [rio_call theme.get [dict create name $::theme_name]]
if {![dict get $_boot_theme ok]} {
	set ::theme_name default
	set _boot_theme [rio_call theme.get {}]
}
apply_theme [dict get $_boot_theme result]
set ::theme_choice $::theme_name
# The Preferences window's Theme control (D58) shows the current theme by its pretty
# label, with a trailing ellipsis — the standard "opens a chooser" affordance, since D92
# turned it from a dropdown into a button onto the shared picker. Keep that display
# string tracking ::theme_choice so a switch from either door (View ▸ Theme… or the
# button) updates the text. One trace, live for the app's life — it writes only a
# variable, harmless whether the window is open.
proc theme_choice_display {} { return "[theme_label $::theme_choice]…" }
set ::theme_choice_label [theme_choice_display]
trace add variable ::theme_choice write \
	{apply {{a b c} {set ::theme_choice_label [theme_choice_display]}}}

# Adopt the core's existing buffer(s), then process the command line. In-process: a
# directory argument opens as the project folder, a file opens in a tab. Remote: the
# path lives on the SERVER, so we can't stat it from here — open each as a project
# folder (project.open) and let the core judge; files are reached via the tree (D29).
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

# Reopen the folder from last launch if argv opened none (D88), so a bare `rio` resumes
# the project instead of a blank pane — and so the workspace restore below has a root to
# key on. Local cores only; a no-op when a project is already open.
reopen_last_project

# Resume the project's workspace: reopen the files that were open last time (D31).
# Only meaningful once a project is open (argv opened one, or reopen_last_project did — or
# none, then this is a no-op); the core prunes vanished paths, so a restore never errors on
# stale entries. Still guarded by ::rio_started=0, so the do_opens here don't each re-save.
session_restore

# Let the window settle at its natural content size, then stop child geometry from
# driving the toplevel. After this, resizing the dock (the sash) flexes the editor
# rather than resizing the whole window — which is what made sash drags feed back
# on themselves. The user can still resize the toplevel via the WM as usual.
update idletasks
pack propagate . 0

# Startup is done: from here, view-state and workspace changes persist (D31).
set ::rio_started 1

# Now ask about anything autosave kept for the files just reopened (D132) — once for the
# whole set, after startup rather than during it, so a restored session raises one dialog
# instead of one per file.
recover_flush

# Look for new versions of the installed extensions, if the user asked for that
# (D107) — off by default, deferred on a timer, and silent about everything but a
# genuine finding. Armed after ::rio_started so a preference written by the
# dialog's "don't check again" persists.
ext_check_arm

# Register the whole window as an OS file-drop target (D86) so a file dropped anywhere —
# a dock, the tab strip, empty editor space — opens (each editor text widget also registers
# itself in make_editor_group, for drops that land on buffer text). Optional tkdnd + local
# core only. Whether that holds headless depends on the host: a bare Linux CI box has no
# tkdnd and this is a no-op, but the Magicsplat distribution bundles it on Windows, where
# the targets really are registered (harmless — nothing can drop onto a withdrawn window).
if {$::have_tkdnd && !$::core_remote} {
	tkdnd::drop_target register . DND_Files
	bind . <<Drop>> {dnd_open_files %D}
}

# The other half of the withdraw at the top of this file: a headless window still has to
# have a real SIZE, or a check that asks whether something FITS its pane reads a layout
# nothing could fit in. So map it once, off-screen, and withdraw it again.
#
# The map is unavoidable, on both platforms, and for different reasons. Windows never sizes
# an unmapped toplevel at all: `winfo width .` stays at the trivial 120x1 and every child
# collapses with it (the tab strip measured 47px). X11 does size one — but a PANEDWINDOW
# lays its panes out only once it is mapped, and rio's editor groups are panes of `.groups`,
# so without the map `.eg0` and the editor widget inside it stay at 1x1 while everything
# around them measures correctly. Only a full `update` maps; `update idletasks` does not.
#
# What is avoidable is the map being visible to the WINDOW MANAGER (D127). A click-to-focus
# WM hands a newly mapped window the input focus, and measured on this box, the X focus
# landed on the editor widget itself — so for those few milliseconds the developer's
# keystrokes went into the boot scratch buffer. One of them is one stray character in a
# buffer every GUI suite assumes is empty, which is what made context_menu.tcl fail about
# one run in twelve.
#
# `wm overrideredirect . 1` is what takes the WM out of it: the window is still mapped and
# `winfo viewable .` is 1, so the geometry is real, but the WM never manages it and so
# cannot focus it. Measured through the map: `focus -displayof .` stays empty and
# _NET_ACTIVE_WINDOW stays on another client, where before both named this process.
# Off-screen at -4000-4000 it is not visible either way. See CAVEATS.md.
if {[info exists ::env(RIO_GUI_HEADLESS)]} {
	wm overrideredirect . 1      ;# the WM never manages it, so it cannot be given the focus
	wm geometry . 1200x800-4000-4000
	wm deiconify .
	update                       ;# a full update: idletasks alone does not MAP it
	wm withdraw .
	# Not on Aqua: there, clearing override-redirect on a window withdrawn from off-screen
	# leaves Tk's event loop with native work it never finishes, so every later full `update`
	# spins forever (Tk 8.6.16, macOS 27; each of the three steps alone is harmless). A
	# headless run never shows `.` again, so keeping the flag costs nothing.
	if {[tk windowingsystem] ne "aqua"} { wm overrideredirect . 0 }
}

# The tripwire for the above, in the idiom ::headless_dialogs already uses: record it here,
# fail the run at exit, so nothing can swallow it.
#
# `focus -displayof .` names the focus widget only when the X input focus really belongs to
# THIS application; it answers with the empty string when it belongs to anyone else. A run
# the WM was never allowed to manage cannot hold it — measured both ways: with a plain map
# this reads `.eg0.t` (the boot editor, which is precisely how a keystroke got into the
# buffer), with the override-redirect one above, the empty string. So a non-empty answer
# here means real input can reach this run, whatever else looks right.
#
# This is not hypothetical arming: before it existed, four suites (browse, pipe, reconnect,
# session) were leaking the focus and nothing said so. Their route in was not the block
# above at all — boot's first blocking op call vwaits, that enters the event loop, and the
# event loop maps a toplevel that has not been withdrawn. Hence the withdraw at the very
# top of this file, and hence a check that asks about the RESULT rather than about any one
# line that could cause it.
#
# One shot, at boot, before any suite has built a toplevel of its own — a suite that maps
# something and focuses it deliberately is not what this is about. Windows is exempt: there
# the WM legitimately manages the map above, so holding the focus is expected.
#
# (Considered instead: log every <KeyPress> and tell real ones from the suite's own
# `event generate` by %t. Dropped — it records the damage rather than preventing it, the
# Text class binding has already inserted the character by the time any `all` binding runs,
# and %t could not be verified here without a human at the keyboard to press a key.)
set ::headless_focus {}
if {[info exists ::env(RIO_GUI_HEADLESS)] && $::tcl_platform(platform) ne "windows"} {
	set ::headless_focus [focus -displayof .]
}

# Headless means there is NO HUMAN at this display — so a blocking dialog has only two
# ways to end, and both are wrong: it waits forever, or it lands on whichever screen the
# suite happens to be running against and waits for a developer to click it. The second is
# what actually happened: a test run asked jka "«zeta.txt» has been deleted on disk. Keep
# it open in the editor?" and their answer silently decided the state the rest of the suite
# then ran against. A suite that needs an answer must supply it itself.
#
# The line, and it is jka's: a dialog that REPORTS something is worth seeing — an error
# message is a diagnostic — while one that ASKS YOU TO DECIDE must never reach a person who
# cannot know whether their answer changes the result. Both halves are served by sending
# the dialog to the test OUTPUT instead of the screen. So each of these writes what it was
# about to ask to stderr (where it survives even a `catch`, and is copy-pasteable in a way
# a screenshot never was) and then raises, failing the suite that reached it.
#
# No informational carve-out: a report_error reaching a test means an op failed where the
# test did not expect it, which is worth failing on — and the message is preserved above.
#
# A suite that MEANS to exercise a dialog overrides these the way it always has
# (`rename tk_messageBox _real_mb ; proc tk_messageBox {args} {...}`) — it now renames this
# guard rather than the real dialog, which changes nothing for it.
#
# Not covered: rio's own tkwait-window modals (name_prompt, pick_dialog,
# remote_browse_dialog, connect_remote_dialog, extw_sources_dialog, keybindings_dialog).
# Each is reached only by an explicit call, so a suite that calls one meant to.
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

	# Raising is not enough on its own. Most dialogs are reached from a timer or event
	# callback, where Tcl hands the error to the background handler and carries on — so a
	# suite can finish, print ALL CHECKS PASSED, and still have asked a question nobody
	# answered. (Observed: exactly that, before the fixture teardown below was fixed.) The
	# recorded list is therefore the authority: a run that asked anything fails, whatever
	# happened to the error afterwards.
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

	# wish's own background-error handler is itself a dialog. Print instead, so a stray
	# error in a callback cannot stop a run either.
	proc bgerror {msg} {
		puts stderr "HEADLESS BGERROR: $msg\n$::errorInfo"
		flush stderr
	}
}

# If keys.json had entries we couldn't use, say so once — a silent skip would leave the
# user's remap mysteriously ineffective. The editor still ran on the valid rest.
if {[llength $::keymap_bad] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
	report_error "Some shortcuts in [keys_path] were ignored:\n  • [join $::keymap_bad "\n  • "]"
}

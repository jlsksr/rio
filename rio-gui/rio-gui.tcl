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

# The parts, one file per concern (ADR-0145). state.tcl first, since the rest read
# it. A part needs no D54 guard: the one above set the system encoding before any
# of them is read.
foreach _m {
	state layout link buffers tabs editor files git chat views dialogs help
	agent prompt find theme highlight prefs keymap repos install extensions
	trust menus widgets
} {
	source [file join $::rio_dir $_m.tcl]
}
unset _m

# ---------------------------------------------------------------------------
# Build the UI. The literal colours/fonts here are just a bootstrap; apply_theme
# (below, fed by the core's theme.get) reconfigures every widget from the role
# table — the default theme reproduces this plain white-bg "90s productivity"
# look (D24), and the View menu switches it live.
# ---------------------------------------------------------------------------
# (Tabs are no longer a single top bar; each editor group draws its own strip, D33.)

# The dock sites (D35 step c1b). Three tabbed tool-window containers —
# left / right / bottom — each a host-owned tab strip (.tabs) above a body area
# (.body) into which the active panel's body widget is packed via -in. This is the
# Visual-Studio docked-tool-window model: every visible site shows its own tab
# strip (render_tabs, from ::layout), and apply_layout drives all of it. It
# replaces the old hand-packed .dock + Files/Git selector: the files/git dock is
# just the two panels that happen to share a side site, and the selector became
# that site's tab strip. Side sites keep a STABLE width (propagate off) like the
# old dock — otherwise the git pane's diff (editor font) is physically wider than
# the file list at the same column count and the window jumps on switch; the
# bottom site takes its content's natural height (the old .results strip).
foreach {_s _w} {left 220 right 340} {
	frame .site$_s -background "#dddddd" -width $_w
	pack propagate .site$_s 0
	frame .site$_s.tabs -background "#dddddd"
	frame .site$_s.body -background "#dddddd"
	pack .site$_s.tabs -side top -fill x
	pack .site$_s.body -side top -fill both -expand 1
}
# The bottom site keeps a STABLE height (propagate off) like the side sites keep a
# stable width — so switching between its tabs (e.g. a tall git diff and the short
# Search strip) never resizes the dock; only the user's bsash drag does.
frame .sitebottom -background "#dddddd" -height 160
pack propagate .sitebottom 0
frame .sitebottom.tabs -background "#dddddd"
frame .sitebottom.body -background "#dddddd"
pack .sitebottom.tabs -side top -fill x
pack .sitebottom.body -side top -fill both -expand 1

# File pane body (D42): a header above a sunken "well" holding the rich-list view —
# a read-only text widget the navigator fills. It is GUI-local CHROME, not a core
# buffer: -state disabled, never renamed/proxied like the editor, never editable.
# The text widget is simply the best stock classic-Tk canvas for per-row glyph icons
# and full-width hover/selection bands (a listbox is text-only, one colour). -width 26
# (cols) keeps the dock's width stable when switching to the git pane (see below).
frame .pfiles -background "#dddddd"
# Files pane header: the project/subdir name (left) + a Refresh glyph (right), the same
# layout as the git pane header so the two panes reload the same way. ⟳ re-lists the
# shown directory and re-reads git flags via populate_nav — the manual counterpart to the
# fs.changed auto-refresh (D47), for changes rio didn't make (an external tool, git pull).
frame .pfiles.hdr -background "#dddddd"
label .pfiles.hdr.head -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .pfiles.hdr.refresh -text "⟳" -font [chrome_font 9] -padx 6 \
	-background "#dddddd" -foreground black
label .pfiles.hdr.hidden -text "◌" -font [chrome_font 9] -padx 6 \
	-background "#dddddd" -foreground black
pack .pfiles.hdr.refresh -side right
pack .pfiles.hdr.hidden  -side right   ;# ◉/◌ toggle for hidden files, left of ⟳ (D62)
pack .pfiles.hdr.head    -side left -fill x -expand 1
pack .pfiles.hdr -side top -fill x
bind .pfiles.hdr.refresh <Button-1> populate_nav
bind .pfiles.hdr.hidden  <Button-1> nav_toggle_hidden
tooltip .pfiles.hdr.refresh "Refresh"   ;# the hidden toggle's tooltip is set (per state) by nav_hidden_glyph
frame .pfiles.well -borderwidth 2 -relief sunken -background white
scrollbar .pfiles.well.sb -command {.pfiles.well.body yview}
text .pfiles.well.body -width 26 -height 10 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .pfiles.well.sb .pfiles.well.body}
pack .pfiles.well -side top -fill both -expand 1
pack .pfiles.well.body -side left -fill both -expand 1
# .pfiles.well.sb is packed on demand by autoscroll (hidden when the list fits).
# The files pane doesn't act on mere selection (onselect empty); a double-click /
# Return opens the row (nav_open); right-click pops a context menu (nav_context_menu).
rl_init .pfiles.well.body {} nav_open nav_context_menu
# D87: the files pane splits the click — a single click on a folder's arrow unfolds it,
# a double-click on the name activates. Override the plain rl_* click binds (set by rl_init)
# on this body only; the git pane keeps the default select-on-single-click behaviour.
bind .pfiles.well.body <Button-1>        {nav_b1 %W %x %y ; break}
bind .pfiles.well.body <Double-Button-1> {nav_b1_double %W %x %y ; break}

# Git pane body: branch header + Refresh, the changed-file list (a rich-list well,
# D43 — same chrome as the file pane), and a read-only diff area below it.
frame .pgit -background "#dddddd"
frame .pgit.hdr -background "#dddddd"
label .pgit.hdr.branch -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .pgit.hdr.refresh -text "⟳" -font [chrome_font 9] -padx 6 \
	-background "#dddddd" -foreground black
# ↩ discards every change in the repo (D93). Built here but NOT packed: refresh_git packs it
# (left of ⟳) only while the repo has changes, so the pane's one destructive control is
# absent from a clean repo — and a mis-click is caught by the No-defaulted confirm anyway.
label .pgit.hdr.discard -text "↩" -font [chrome_font 9] -padx 6 \
	-background "#dddddd" -foreground black
set ::git_change_count 0
pack .pgit.hdr.refresh -side right
pack .pgit.hdr.branch  -side left -fill x -expand 1
pack .pgit.hdr -side top -fill x
bind .pgit.hdr.refresh <Button-1> refresh_git
bind .pgit.hdr.discard <Button-1> git_discard_all_confirm
tooltip .pgit.hdr.refresh "Refresh"
tooltip .pgit.hdr.discard "Discard all changes"
frame .pgit.well -borderwidth 2 -relief sunken -background white
scrollbar .pgit.well.sb -command {.pgit.well.body yview}
text .pgit.well.body -width 26 -height 8 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .pgit.well.sb .pgit.well.body}
# -width 26 matches the file pane so the git pane does not balloon the dock (and the
# whole window) to the text widget's default 80 columns when it is shown.
text .pgit.diff -wrap none -width 26 -height 8 -state disabled \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black
ctx_bind_view .pgit.diff   ;# Copy / Select All (D115)
pack .pgit.well -side top -fill both -expand 1
pack .pgit.well.body -side left -fill both -expand 1
# .pgit.well.sb is packed on demand by autoscroll; .pgit.diff by git_show_diff.
# Picking a change (single click / arrow) shows its diff (git_pick); no separate
# activate; right-click pops a context menu (git_context_menu).
rl_init .pgit.well.body git_pick {} git_context_menu

# The commit bar (D45): rio's first inline text-input in a dock pane. A single-line
# summary entry + a Commit button, packed at the bottom of the git pane by refresh_git
# ONLY when something is staged (and hidden otherwise) — "appears only when needed", the
# D36 find-bar quality bar. Enter in the entry commits too. The ＋ toggle reveals an
# optional multi-line description (D80), joined to the summary as git's subject+body.
# Built here, not packed; git_commit_body_set lays out the row (body collapsed to start).
set ::git_commit_body_shown 0
frame  .pgit.commit -background "#dddddd"
entry  .pgit.commit.msg  -font [chrome_font 9] -textvariable git_commit_msg
button .pgit.commit.more -text "＋" -font [chrome_font 9] -takefocus 0 -command git_commit_body_toggle
button .pgit.commit.go   -text "✓ Commit" -font [chrome_font 9] -command git_commit
text   .pgit.commit.body -height 4 -font [chrome_font 9] -wrap word -undo 1 \
	-borderwidth 1 -relief solid -highlightthickness 0
# A greyed "message" hint, shown only while the entry is empty (Tk has no native
# placeholder). It is a child label placed inside the entry, so it never becomes part of
# `.msg get` — the empty check and the commit stay honest. A trace toggles it on content.
label .pgit.commit.msg.ph -text message -font [chrome_font 9] -takefocus 0 -borderwidth 0
place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
bind  .pgit.commit.msg.ph <Button-1> {focus .pgit.commit.msg}
# The body's own placeholder, same device — a child label over the text widget.
label .pgit.commit.body.ph -text "Longer description (optional)" -font [chrome_font 9] \
	-takefocus 0 -borderwidth 0
bind  .pgit.commit.body.ph <Button-1> {focus .pgit.commit.body}
# Cut/Copy/Paste/Select All on both fields (D115). The placeholder labels are PLACED ON
# TOP of them, so a right-click on an empty commit bar would hit the label and never
# reach the field — forward it, exactly as each label already forwards Button-1.
ctx_bind_input .pgit.commit.msg
ctx_bind_input .pgit.commit.body
ctx_bind_placeholder .pgit.commit.msg.ph  .pgit.commit.msg  input
ctx_bind_placeholder .pgit.commit.body.ph .pgit.commit.body input
trace add variable git_commit_msg write git_commit_hint
bind .pgit.commit.body <KeyRelease> git_commit_body_hint
bind .pgit.commit.body <FocusIn>    git_commit_body_hint
bind .pgit.commit.body <FocusOut>   git_commit_body_hint
tooltip .pgit.commit.more "Add a longer description"
git_commit_body_set 0   ;# summary row only; body hidden until ＋
# Enter in the one-line summary commits; in the multi-line body it inserts a newline, so
# Ctrl+Enter is the commit chord there (and works from the summary too, for muscle memory).
# On a Mac, ⌘Enter as well (D136).
bind .pgit.commit.msg  <Return>         git_commit
foreach _m [lsort -unique [list Control $::primary_mod]] {
	bind .pgit.commit.msg  <$_m-Return> git_commit
	bind .pgit.commit.body <$_m-Return> {git_commit ; break}
}
unset _m

# A thin draggable divider between the dock and the editor. apply_layout parks it on
# whichever edge the dock occupies; dragging it resizes the dock (the editor, which
# -expands, absorbs the difference). The resize cursor on hover advertises the grip.
frame .sash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .sash <B1-Motion> sash_drag
# Record the dock's final width into its site on release (sizes persist now, D35 b).
bind .sash <ButtonRelease-1> { rio::layout::put left size [winfo width .siteleft] ; prefs_save }

# A horizontal divider between the editor and the bottom dock; dragging it resizes
# the bottom site's HEIGHT (the editor, which -expands, absorbs the difference).
frame .bsash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .bsash <B1-Motion> bsash_drag
bind .bsash <ButtonRelease-1> { rio::layout::put bottom size [winfo height .sitebottom] ; prefs_save }

# The editor region (D33). The center is a .groups panedwindow that holds one
# or two editor GROUPS side by side with a draggable divider; each group is an
# independent text widget (with its own tab strip, scrollbars, and highlight cache)
# built by make_editor_group. Each text widget is renamed to a real command (::real<g>)
# and driven through a proxy proc at its Tk path so class bindings still call
# `.eg<g>.t insert`, which the proxy turns into protocol requests (the D3 dumb-view
# discipline, now per group). The horizontal bar auto-hides (gridscroll) when no line
# overflows, and apply_wrap drops it entirely while wrapping.
panedwindow .groups -orient horizontal -borderwidth 0 \
	-sashwidth 6 -sashrelief raised -opaqueresize 1

# Resolve the keymap (defaults + the user's keys.json) before any binding or menu is
# built, so both the editor shortcuts and the menu accelerators read the same table.
keymap_resolve
set ::keymap_live_chords [keymap_chords] ;# what the first group's editor_bindings will bind

# Create the first editor group; the split adds a second (phase 3).
make_editor_group 0
set ::groups {0}
set ::focus 0
relayout_groups

# The compare / diff view (D28): two read-only text panes side by side
# with a single shared vertical scrollbar, packed in the center INSTEAD of .ed
# while comparing (apply_layout). Built here with bootstrap colours; apply_theme
# recolours them and configures the del/add/filler row tags. cmp_fill renders the
# core diff.lines alignment into the panes.
frame .cmp
frame .cmp.l ; frame .cmp.r
label .cmp.l.hdr -anchor w -font [chrome_font 9] -padx 4 -pady 2 -background "#dddddd" -foreground black
label .cmp.r.hdr -anchor w -font [chrome_font 9] -padx 4 -pady 2 -background "#dddddd" -foreground black
text .cmp.l.t -wrap none -state disabled -font [chrome_font 12] -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll l}
text .cmp.r.t -wrap none -state disabled -font [chrome_font 12] -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll r}
ctx_bind_view .cmp.l.t ; ctx_bind_view .cmp.r.t   ;# Copy / Select All (D115)
scrollbar .cmp.sb -orient vertical -command cmp_yview
# A top bar with a clear way out — the Esc binding alone isn't discoverable, so the
# button names the shortcut (D27: a plain × glyph, widely covered).
frame .cmp.bar
button .cmp.bar.close -text "× Close compare (Esc)" -font [chrome_font 9] -command compare_close
pack .cmp.bar.close -side right -padx 2 -pady 1
pack .cmp.bar -side bottom -fill x
pack .cmp.l.hdr -side top -fill x ; pack .cmp.l.t -side left -fill both -expand 1
pack .cmp.r.hdr -side top -fill x ; pack .cmp.r.t -side left -fill both -expand 1
pack .cmp.l  -side left  -fill both -expand 1
pack .cmp.sb -side right -fill y
pack .cmp.r  -side left  -fill both -expand 1
foreach w {.cmp.l.t .cmp.r.t} {
	bind $w <MouseWheel> {cmp_yview scroll [expr {%D > 0 ? -1 : 1}] units ; break}
	bind $w <Button-4>   {cmp_yview scroll -1 units ; break}
	bind $w <Button-5>   {cmp_yview scroll 1 units ; break}
	bind $w <Escape>     {compare_close ; break}
}

# The plan view (D101): one read-only pane in the center, rendering the agent's
# plan with the manual's renderer (plan_open). Same chrome as the compare view — a titled
# header and a bottom bar whose button names the Esc shortcut — because it is the same kind
# of thing: a proposal being read before it is decided. Wrapped, not scrolled sideways:
# this is prose, and help_paint's own code/table tags handle what must not reflow.
frame .plan
label .plan.hdr -anchor w -font [chrome_font 9] -padx 4 -pady 2 -background "#dddddd" -foreground black
text .plan.text -wrap word -state disabled -font [chrome_font 12] -width 80 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 12 -pady 8 \
	-background white -foreground black -yscrollcommand {.plan.sb set}
ctx_bind_view .plan.text   ;# Copy / Select All (D115)
scrollbar .plan.sb -orient vertical -command {.plan.text yview}
frame .plan.bar
button .plan.bar.close -text "× Close plan (Esc)" -font [chrome_font 9] -command plan_close
pack .plan.bar.close -side right -padx 2 -pady 1
pack .plan.bar -side bottom -fill x
pack .plan.hdr -side top -fill x
pack .plan.sb -side right -fill y
pack .plan.text -side left -fill both -expand 1
bind .plan.text <Escape> {plan_close ; break}

# The agent chat pane (built here; apply_layout packs it on the right when shown,
# apply_theme colours it via the chat.* roles + RioChatFont). propagate off so a
# fixed -width holds across content, like the dock. A header (Agent + Clear) on
# top, the composer (input + Send) at the bottom, the transcript filling between.
frame .chat -width 340 -background white
pack propagate .chat 0
frame .chat.hdr -background white
label .chat.hdr.title -text "Agent" -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-background white -foreground black
label .chat.hdr.clear -text "Clear" -font [chrome_font 9] -padx 6 -cursor hand2 \
	-background white -foreground black
# The agent's mode, where it was already being displayed — but as a control (D102). Three
# exclusive states over the core's two flags: Plan (may read, may not change), Review (each
# edit waits), Auto (edits apply as they come). The header is the pane's control strip
# already (Clear lives here, as ⟳ and the hidden toggle do in the Files and Git headers),
# and a one-word label needs the tooltip to say what it means.
menubutton .chat.hdr.mode -text "Review ▾" -font [chrome_font 9] -menu .chat.hdr.mode.m \
	-padx 4 -cursor hand2 -background white -foreground black
menu .chat.hdr.mode.m -tearoff 0
foreach {v lbl} {plan "Plan — read and plan, change nothing" \
		review "Review each edit" auto "Auto-accept edits"} {
	.chat.hdr.mode.m add radiobutton -label $lbl -variable ::agent_mode_ui -value $v \
		-command agent_mode_set
}
pack .chat.hdr.clear -side right
pack .chat.hdr.mode  -side right
pack .chat.hdr.title -side left -fill x -expand 1
bind .chat.hdr.clear <Button-1> chat_clear
# Composer: a few-line input + a Send button. Enter sends; Shift+Enter newlines.
text .chat.input -height 3 -wrap word -undo 1 -font [chrome_font 11] \
	-borderwidth 1 -relief solid -highlightthickness 0 -padx 3 -pady 2 \
	-background white -foreground black -insertbackground black
ctx_bind_input .chat.input   ;# Cut / Copy / Paste / Select All (D115)
button .chat.send -text "▶" -font [chrome_font 9] -command chat_send  ;# ▶ send (D27)
# …and ■ stop while a turn is working (D104): the same button, because "send" and "stop"
# are never both available — the turn is either yours to type into or the agent's to run.
tooltip .chat.send "Send this message"
# Status strip at the pane's very bottom: on the left the agent you are talking to —
# provider, model, and any option that is not at its default — as a CONTROL (D106),
# on the right the working indicator. They used to be one label, which meant the
# animation erased the answer to "which model is this?" for the whole time it mattered
# most. This is also where the eye already is: directly under the composer.
frame .chat.status -background "#eeeeee"
menubutton .chat.status.sel -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-menu .chat.status.sel.m -cursor hand2 \
	-background "#eeeeee" -foreground "#444444"
menu .chat.status.sel.m -tearoff 0
label .chat.status.busy -anchor e -font [chrome_font 9] -padx 4 -pady 2 \
	-background "#eeeeee" -foreground "#444444"
pack .chat.status.sel  -side left
pack .chat.status.busy -side right
bind .chat.input <Return>       { chat_send ; break }
bind .chat.input <Shift-Return> { %W insert insert "\n" ; break }
# A thin draggable divider between the transcript and the composer, so the user can
# size the input box (mirror of .sash/.csash, but horizontal).
frame .chat.isash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .chat.isash <ButtonPress-1> { isash_press %Y }
bind .chat.isash <B1-Motion>     { isash_drag %Y }
bind .chat <Configure> clamp_input_height
# Approve/Reject bar for a proposed edit (packed on demand by approve_bar; D26 s5).
frame .chat.approve -background white
label .chat.approve.lbl -text "Apply this edit?" -anchor w -font [chrome_font 9] \
	-padx 4 -pady 2 -background white -foreground black
button .chat.approve.yes -text "Approve" -font [chrome_font 9] -command {agent_decide approve}
button .chat.approve.no  -text "Reject"  -font [chrome_font 9] -command {agent_decide reject}
button .chat.approve.cmp -text "Compare" -font [chrome_font 9] -command {compare_proposal $::pending_turn}
# "Plan" (plan proposals only, D101): reopen the plan the user closed while thinking. The
# plan is already in hand — nothing is fetched, it is only shown again.
button .chat.approve.plan -text "Plan" -font [chrome_font 9] -command plan_reopen
# A plan is approved WITH a policy for the work it starts (D102): the two items are the two
# ways to say yes, so "approve" never silently means one of them. A menubutton rather than
# two buttons because the choice is the approval, not a setting beside it.
menubutton .chat.approve.appr -text "Approve ▾" -font [chrome_font 9] \
	-menu .chat.approve.appr.m -relief raised -borderwidth 1 -padx 4
menu .chat.approve.appr.m -tearoff 0
.chat.approve.appr.m add command -label "Approve — review each edit" \
	-command {agent_decide_plan review}
.chat.approve.appr.m add command -label "Approve — auto-accept edits" \
	-command {agent_decide_plan auto}
# "Edit plan" (plan proposals only, D102): the plan is a file in the project, so changing it
# is rio's ordinary edit path. Packed only when the plan was filed.
button .chat.approve.edit -text "Edit plan" -font [chrome_font 9] -command plan_edit
# "Always allow" (command proposals only, D84): remember a trust rule so this command
# stops asking. Packed on demand by approve_bar; its menu is rebuilt per proposal by
# chat_allow_menu_populate. tearoff off — a floating menu makes no sense here.
menubutton .chat.approve.always -text "Always allow ▾" -font [chrome_font 9] \
	-menu .chat.approve.always.m -relief raised -borderwidth 1 -padx 4
menu .chat.approve.always.m -tearoff 0
pack .chat.approve.yes -side right
pack .chat.approve.no  -side right
pack .chat.approve.cmp -side right
pack .chat.approve.lbl -side left -fill x -expand 1
# Transcript: read-only, word-wrapped, with an auto-hiding scrollbar.
text .chat.log -wrap word -state disabled -font [chrome_font 11] -cursor "" \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .chat.sb .chat.log}
ctx_bind_view .chat.log   ;# Copy / Select All (D115)
scrollbar .chat.sb -command {.chat.log yview}
.chat.log tag configure you-label   -font [chrome_font 9] -background "#c3d9ff" \
	-spacing1 4 -spacing3 2
.chat.log tag configure agent-label -font [chrome_font 9] -background "#dddddd" \
	-spacing1 4 -spacing3 2
.chat.log tag configure error-label -font [chrome_font 9]
.chat.log tag configure tool        -font [chrome_font 9] -foreground "#888888"
.chat.log tag configure tool-error  -font [chrome_font 9] -foreground "#cc0000"
.chat.log tag configure thinking    -font [chrome_font 9] -foreground "#888888" \
	-lmargin1 12 -lmargin2 12
.chat.log tag configure diff-add    -font [chrome_font 9] -foreground "#118811"
.chat.log tag configure diff-del    -font [chrome_font 9] -foreground "#cc0000"
pack .chat.hdr    -side top    -fill x
pack .chat.status -side bottom -fill x
pack .chat.send   -side bottom -fill x
pack .chat.input  -side bottom -fill x
pack .chat.isash  -side bottom -fill x
pack .chat.log    -side left   -fill both -expand 1
# .chat.sb is packed on demand by autoscroll (hidden when the transcript fits).

# A thin draggable divider between the editor and the chat pane (mirror of .sash).
frame .csash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .csash <B1-Motion> csash_drag
# Record the chat column's final width into the right site on release (D35 b).
bind .csash <ButtonRelease-1> { rio::layout::put right size [winfo width .siteright] ; prefs_save }

# The find/replace bar (D36): built hidden; find_open packs it above the status
# bar. Row 0 finds, row 1 replaces (gridded away in find-only mode). Plain
# labelled controls and a × to close (D27) — the bar reads at a glance. Colours
# are bootstrap; apply_theme restyles (entries take the editor surface).
frame .find -borderwidth 1 -relief raised -background "#dddddd"
label .find.fl -text "Find:"    -font [chrome_font 9] -anchor e -background "#dddddd"
label .find.rl -text "Replace:" -font [chrome_font 9] -anchor e -background "#dddddd"
entry .find.e  -font [chrome_font 11] -width 24
entry .find.re -font [chrome_font 11] -width 24
ctx_bind_input .find.e ; ctx_bind_input .find.re   ;# Cut / Copy / Paste / Select All (D115)
# ↓/↑ (U+2193/U+2191) step forward/backward through matches (top-to-bottom),
# the find-widget idiom (D27); F3 / Shift+F3 are the keyboard path.
button .find.next -text "↓" -width 2 -font [chrome_font 9] -command find_next
button .find.prev -text "↑" -width 2 -font [chrome_font 9] -command find_prev
checkbutton .find.case -text "Match case" -font [chrome_font 9] \
	-variable ::find_case -command find_update -background "#dddddd"
checkbutton .find.word -text "Whole word" -font [chrome_font 9] \
	-variable ::find_word -command find_update -background "#dddddd"
checkbutton .find.regex -text "Regex" -font [chrome_font 9] \
	-variable ::find_regex -command find_regex_changed -background "#dddddd"
label .find.count -font [chrome_font 9] -anchor w -background "#dddddd"
label .find.close -text "×" -font [chrome_font 9] -padx 6 -cursor hand2 \
	-background "#dddddd"
button .find.rep    -text "Replace"     -font [chrome_font 9] -command find_replace_one
button .find.repall -text "Replace All" -font [chrome_font 9] -command find_replace_all
grid .find.fl     -row 0 -column 0 -sticky e  -padx {6 2} -pady 2
grid .find.e      -row 0 -column 1 -sticky ew -pady 2
grid .find.next   -row 0 -column 2 -padx 2
grid .find.prev   -row 0 -column 3 -padx 2
grid .find.case   -row 0 -column 4 -padx 4
grid .find.word   -row 0 -column 5 -padx 4
grid .find.regex  -row 0 -column 6 -padx 4
grid .find.count  -row 0 -column 7 -sticky ew -padx 4
grid .find.close  -row 0 -column 8 -sticky e  -padx {2 6}
grid .find.rl     -row 1 -column 0 -sticky e  -padx {6 2} -pady {0 2}
grid .find.re     -row 1 -column 1 -sticky ew -pady {0 2}
grid .find.rep    -row 1 -column 2 -padx 2 -pady {0 2}
grid .find.repall -row 1 -column 3 -columnspan 2 -sticky w -padx 2 -pady {0 2}
grid columnconfigure .find 1 -weight 1
grid columnconfigure .find 7 -weight 1
bind .find.close <Button-1> find_close
# Both entries: Enter steps (Shift-Enter steps back), Esc closes, F3 works too.
# In the Replace entry, Enter replaces instead — you are aiming at a replace.
foreach _w {.find.e .find.re} {
	bind $_w <Return>       {find_next ; break}
	bind $_w <Shift-Return> {find_prev ; break}
	bind $_w <Escape>       {find_close ; break}
	bind $_w <F3>           {find_next ; break}
	bind $_w <Shift-F3>     {find_prev ; break}
	# Escalate to the full Search panel (D52), carrying the bar's needle + options.
	# Bound here too because the group-widget keymap chord doesn't fire while a bar
	# entry holds focus.
	# The search chord, so a Mac gets ⇧⌘F (D136); none if keys.json unbound it.
	if {[set _c [key_chord search]] ne ""} { bind $_w <$_c> {search_from_bar ; break} }
}
bind .find.re <Return> {find_replace_one ; break}
bind .find.e  <KeyRelease> find_update
unset _w

# The Search panel (D52), a D35 dock tenant. Its controls are BOTTOM-anchored like the
# Agent composer, not a top header: Search and Chat are both "compose" panes (a real
# input field + full controls), so their controls hug the bottom edge and the content
# accumulates above — the type-here/output-above idiom, and the input lands in the same
# place when switching between them. (Files/Git differ: their chrome is a *thin* caption
# — a name + a glyph button — so it sits at the top. The split is by control weight, not
# by pane; see D35.) So the sunken well of results fills the top and the query
# row (needle + scope + Match case + Whole word + count + ×) is pinned to the bottom;
# Ctrl+H toggles the replace row in just ABOVE it, so the query field never moves. The
# scope option menu picks the engine (Project vs Open docs vs Current doc). Colours are
# bootstrap; apply_theme restyles (the query entry the editor surface, the well the chrome).
frame .results -borderwidth 1 -relief raised -background "#dddddd"
frame .results.hdr -background "#dddddd"
label .results.hdr.l -text "Search:" -font [chrome_font 9] -background "#dddddd"
entry .results.hdr.e -font [chrome_font 11] -width 28
ctx_bind_input .results.hdr.e   ;# (D115)
# The scope option menu drives ::search_scope; each entry re-runs the query so a
# scope change is live (like the option toggles). tk_optionMenu returns the menu.
set _scopemenu [tk_optionMenu .results.hdr.scope ::search_scope "Project" "Open docs" "Current doc"]
for {set _i 0} {$_i <= [$_scopemenu index end]} {incr _i} {
	$_scopemenu entryconfigure $_i -command search_run
}
.results.hdr.scope configure -font [chrome_font 9] -background "#dddddd" \
	-highlightthickness 0 -borderwidth 1 -relief raised -padx 4 -pady 0
unset _scopemenu _i
checkbutton .results.hdr.case -text "Match case" -font [chrome_font 9] \
	-variable ::search_case -command search_run -background "#dddddd"
checkbutton .results.hdr.word -text "Whole word" -font [chrome_font 9] \
	-variable ::search_word -command search_run -background "#dddddd"
checkbutton .results.hdr.regex -text "Regex" -font [chrome_font 9] \
	-variable ::search_regex -command search_regex_changed -background "#dddddd"
label .results.hdr.count -font [chrome_font 9] -anchor w -background "#dddddd"
label .results.hdr.close -text "×" -font [chrome_font 9] -padx 6 -cursor hand2 -background "#dddddd"
pack .results.hdr.l     -side left  -padx {6 2} -pady 2
pack .results.hdr.e     -side left  -pady 2
pack .results.hdr.scope -side left  -padx 6
pack .results.hdr.case  -side left  -padx 6
pack .results.hdr.word  -side left  -padx {0 4}
pack .results.hdr.regex -side left  -padx {0 6}
pack .results.hdr.close -side right -padx {2 6}
pack .results.hdr.count -side right -padx 6
pack .results.hdr -side bottom -fill x   ;# controls hug the bottom edge (compose pane)
# The replace row (D52 Phase B): built hidden; search_show_replace (Ctrl+H) packs it
# just ABOVE the bottom-anchored query row. Replacement entry + Replace All — the scope
# selector on the query row below decides where it lands (buffers vs disk, confirm-gated).
frame .results.rep -background "#dddddd"
label .results.rep.l -text "Replace:" -font [chrome_font 9] -background "#dddddd"
entry .results.rep.e -font [chrome_font 11] -width 28
ctx_bind_input .results.rep.e   ;# (D115)
button .results.rep.all -text "Replace All" -font [chrome_font 9] -command search_replace_all
pack .results.rep.l   -side left -padx {6 2} -pady {0 2}
pack .results.rep.e   -side left -pady {0 2}
pack .results.rep.all -side left -padx 6
frame .results.well -borderwidth 2 -relief sunken -background white
scrollbar .results.well.sb -command {.results.well.body yview}
text .results.well.body -width 40 -height 8 -wrap none -state disabled \
	-cursor arrow -insertwidth 0 -takefocus 1 \
	-borderwidth 0 -highlightthickness 0 -padx 2 -pady 1 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .results.well.sb .results.well.body}
pack .results.well -side top -fill both -expand 1
pack .results.well.body -side left -fill both -expand 1
# .results.well.sb is packed on demand by autoscroll. A double-click / Return on a
# match row goes to it (search_activate); mere selection does nothing.
rl_init .results.well.body {} search_activate {}
bind .results.hdr.e    <Return>    {search_run ; break}
bind .results.hdr.e    <Escape>    {search_close ; break}
# The replace chord toggles the row, as in the find bar: ⌥⌘F on a Mac (D136).
if {[set _c [key_chord replace]] ne ""} {
	bind .results.hdr.e <$_c> {search_show_replace 1 ; break}
	bind .results.rep.e <$_c> {search_show_replace 0 ; focus .results.hdr.e ; break}
}
unset _c
bind .results.rep.e    <Return>    {search_replace_all ; break}
bind .results.rep.e    <Escape>    {search_close ; break}
bind .results.hdr.close <Button-1> search_close

# Register the four tool panes now that their body widgets exist (D35 step
# (a)). Placement is still owned by apply_layout / show_pane — this only
# declares each pane as data and gives its refresh a name. Files and git are separate
# panels sharing today's side dock; chat is event-driven (no batch refresh hook).
rio::panel::register files  {title Files  site left   body .pfiles refresh populate_nav}
rio::panel::register git    {title Git    site left   body .pgit   refresh refresh_git}
rio::panel::register chat   {title Agent  site right  body .chat       refresh {}}
rio::panel::register search {title Search site bottom body .results    refresh search_run}

label .status -anchor w -font [chrome_font 9] -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
# The dock sites and .groups are packed by apply_layout at startup (from the layout);
# each editor group's tab strip lives inside its own frame (D33), not a global top bar.
focus [gget 0 path]

# Menus use stock Tk behaviour. An earlier tweak (D59, reverted) rebound the Menu
# class's <ButtonRelease> and renamed tk::MenuFirstEntry so a click wouldn't pre-highlight a
# dropdown's first entry (to match a hover-slide). It reached into Tk's menu grab/post state
# machine and caused intermittent misfires — a click invoking the first item, or a post that
# stuck — so it was removed. The cosmetic click-vs-hover first-entry difference is accepted
# as stock Tk. Don't re-add that override without a non-invasive mechanism.
menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator [key_accel new]         -command do_new
.m.file add command -label "Open…"    -accelerator [key_accel open]        -command open_dialog
.m.file add command -label "Open Folder…" -accelerator [key_accel open-folder] -command open_folder_dialog
.m.file add command -label "Save"      -accelerator [key_accel save]        -command do_save
.m.file add command -label "Save As…" -accelerator [key_accel save-as]     -command save_as_dialog
.m.file add separator
.m.file add command -label "Connect to Remote Core…" -command connect_remote_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator [key_accel close-tab]   -command do_close
.m.file add command -label "Quit"      -accelerator [key_accel quit]        -command do_quit
# Undo/Redo and the clipboard block (Win98 canon) come from editor_menu_items — the
# ONE table the editor's right-click menu is built from too (D108), so the two doors
# offer the same actions, on the same procs, greyed by the same rules. The commands
# work in every editing mode; -postcommand re-derives the greys for the focused group
# each time the menu is posted.
menu .m.edit -tearoff 0 -postcommand editor_menu_post
.m add cascade -label Edit -menu .m.edit
editor_menu_fill .m.edit [editor_menu_items [gget $::focus path]]
# Find / Replace / Search moved out to their own top-level Find menu (D75) — see below.
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
# The four tool panes toggle from here — a checkmark shows whether each is currently
# on screen (site visible + its active tab); clicking shows or hides it (panel_toggle).
# Ctrl+E/G stay quick "reveal" keys (idempotent go-to); the Agent's Ctrl+Shift+A
# toggles it (a solo pane, so no ambiguity).
.m.view add checkbutton -label "Files"  -accelerator [key_accel show-files] \
	-variable ::shown_files  -command {panel_toggle files}
.m.view add checkbutton -label "Git"    -accelerator [key_accel show-git] \
	-variable ::shown_git    -command {panel_toggle git}
.m.view add checkbutton -label "Agent"  -accelerator [key_accel toggle-chat] \
	-variable ::shown_chat   -command {panel_toggle chat}
.m.view add checkbutton -label "Search" \
	-variable ::shown_search -command {panel_toggle search}
.m.view add separator
.m.view add checkbutton -label "Wrap Lines" -accelerator [key_accel toggle-wrap] \
	-variable ::wrap_lines -command apply_wrap
.m.view add checkbutton -label "Indent Wrapped Lines" \
	-variable ::wrap_indent -command apply_wrap_indent
.m.view add checkbutton -label "Line Numbers" -accelerator [key_accel toggle-linenums] \
	-variable ::line_numbers -command apply_line_numbers
.m.view add checkbutton -label "Highlight Current Line" \
	-variable ::highlight_current_line -command apply_curline
.m.view add checkbutton -label "Relative Line Numbers" \
	-variable ::relative_line_numbers -command apply_relnum
# How the editor tab strip lays out when tabs outrun the width (D57): scroll (one line
# behind ◂ ▸ arrows) or multi (wrap onto rows). A view preference, so it sits with its
# display-toggle neighbors above — a view preference, not a navigation action like the
# Switch to Tab… picker below.
.m.view add checkbutton -label "Multi-Line Tabs" \
	-onvalue multi -offvalue scroll -variable ::tab_layout -command tab_layout_apply
.m.view add checkbutton -label "Show Hidden Files" \
	-variable ::show_hidden -command apply_show_hidden
.m.view add separator
# Switch to Tab… replaces the old top-level Tabs menu (D74): the reliable way to reach a
# buffer when the window is too narrow to show its tab handle. It opens the bounded
# buffer-picker dialog (which also backs Compare ▸ Compare With Another Tab…) instead of an
# unbounded cascade that could grow screen-tall on X11 — and the dialog shows a path hint so
# two same-named tabs are told apart. A navigation command, so it heads the lower group.
.m.view add command -label "Switch to Tab…" -command switch_tab_dialog
# Less-frequent items live in topical submenus so the View menu stays short enough to fit
# on screen (D64). A Tk menu posted taller than the space below it misbehaves on X11 (it can
# unpost on a mid-list hover); we keep it in check by grouping, not by patching Tk's menu
# machinery (the D59 lesson). The display toggles above stay top-level — they are the ones
# flicked often. Each cascade below is built the same way.
menu .m.view.dock -tearoff 0
.m.view add cascade -label "Dock Side" -menu .m.view.dock
.m.view.dock add radiobutton -label "Left"  -variable ::dock_side -value left  -command {dock_set_side left}
.m.view.dock add radiobutton -label "Right" -variable ::dock_side -value right -command {dock_set_side right}
menu .m.view.zoom -tearoff 0
.m.view add cascade -label "Font & Zoom" -menu .m.view.zoom
.m.view.zoom add command -label "Font…"      -command editor_font_dialog
.m.view.zoom add separator
.m.view.zoom add command -label "Zoom In"    -accelerator "$::primary_label++" -command {editor_zoom 1}
.m.view.zoom add command -label "Zoom Out"   -accelerator "$::primary_label+-" -command {editor_zoom -1}
.m.view.zoom add command -label "Reset Zoom" -accelerator "$::primary_label+0" -command editor_zoom_reset
menu .m.view.layout -tearoff 0
.m.view add cascade -label "Editor Layout" -menu .m.view.layout
.m.view.layout add command -label "Split Editor"          -accelerator [key_accel split-editor] -command split_editor
.m.view.layout add command -label "Unsplit Editor"        -command unsplit_editor
.m.view.layout add command -label "Move Tab to Other Group" -accelerator [key_accel move-tab-other] -command move_tab_other
# Theme… opens the bounded picker (D92), not a cascade: the theme list grows with every
# installed theme (D39), so it was the one menu here with no size bound at all.
.m.view add command -label "Theme…" -command theme_pick_dialog
# Language… (D112) picks the current buffer's highlighter by hand. Also a bounded picker:
# the language list grows with every installed syntax extension, just like themes.
.m.view add command -label "Language…" -command language_pick_dialog
# Extensions… is NOT here (it moved to Settings in D67, and to its own top-level menu in
# D130): it is a management dialog that
# installs the providers/modes/themes the choosers pick, not a pane toggle.

# Find is its own top-level menu (D75), holding the search cluster that used to sit behind a
# separator in Edit — in-buffer Find/Replace/Next/Previous plus project-wide Search…. Lifting
# the whole coherent group (not splitting it) leaves Edit as the classic clipboard/selection
# ops and gives search a discoverable home, in the spirit of Sublime's top-level Find menu.
# Named "Find", not "Search", so it doesn't collide with the View ▸ Search *pane* toggle;
# four of its five items are Find anyway. Placed left of Compare — both are editor-action
# menus to the right of View.
menu .m.find -tearoff 0
.m add cascade -label Find -menu .m.find
.m.find add command -label "Find…"         -accelerator [key_accel find]      -command {find_open 0}
.m.find add command -label "Replace…"      -accelerator [key_accel replace]   -command {find_open 1}
.m.find add command -label "Find Next"     -accelerator [key_accel find-next] -command find_next
.m.find add command -label "Find Previous" -accelerator [key_accel find-prev] -command find_prev
.m.find add separator
.m.find add command -label "Search…"       -accelerator [key_accel search]    -command search_open

# Compare is its own top-level menu, not a View ▸ Editor Layout item (D73): the diff view
# (D28) is a distinct mode that swaps the whole editor surface for two read-only panes —
# it is not one of the split/unsplit/move-tab *layouts* of the editing groups, so it read
# as misplaced there. A short top-level menu makes the mode discoverable and gives the
# agent's own "opened in compare view" flow a named home the user can reach directly.
menu .m.compare -tearoff 0
.m add cascade -label Compare -menu .m.compare
# Another Tab comes first — comparing the active buffer against another open tab is the
# more frequent case than against a file on disk (D74); both open the same modal picker /
# file chooser respectively.
.m.compare add command -label "Compare With Another Tab…" -command compare_with_tab_dialog
.m.compare add command -label "Compare With A File…" -command compare_with_file_dialog
.m.compare add separator
.m.compare add command -label "Close Compare" -accelerator Esc -command compare_close
menu .m.settings -tearoff 0
.m add cascade -label Settings -menu .m.settings
# The Preferences window (D58) gathers every stateful setting in one place; the items
# below stay here too — it is a second door, not a replacement.
.m.settings add command -label "Preferences…" -accelerator [key_accel preferences] \
	-command preferences_window
# Extensions… is NOT here any more (D130, amending D67): it leads the top-level
# Extensions menu, alongside the per-extension settings doors, so everything to do with
# extensions is in one place. This menu keeps rio's own fast switches.
.m.settings add separator
# The agent provider is a cascade filled from the core (providers_menu_fill, mirroring
# View ▸ Theme): the list scales as providers are added (D39/milestone B), and the
# collapsed menu stays short. Choosing which model is live is a quick runtime switch,
# so it earns a menu home; the provider's heavier configuration — its API key, its
# prompts, its command allow-list — lives only in the Preferences Agent pane (jka,
# 2026-09-09), keeping this menu to fast toggles.
menu .m.settings.provider -tearoff 0
.m.settings add cascade -label "Agent Provider" -menu .m.settings.provider
# The agent's mode and compare-complex are the agent settings flipped often enough
# mid-session to keep here alongside the provider (their twins live in Preferences too).
# The mode leads: it decides whether the agent may change anything at all, and it is chosen
# at the START of a piece of work, which is when this menu is open (D101). Three exclusive
# states, not two checkboxes, so the menu cannot show a combination the pane cannot (D102);
# same variable and same writer as the chat header's control.
menu .m.settings.agentmode -tearoff 0
foreach {v lbl} {plan "Plan — read and plan, change nothing" \
		review "Review each edit" auto "Auto-accept edits"} {
	.m.settings.agentmode add radiobutton -label $lbl -variable ::agent_mode_ui -value $v \
		-command agent_mode_set
}
.m.settings add cascade -label "Agent Mode" -menu .m.settings.agentmode
.m.settings add checkbutton -label "Agent: Compare complex edits" \
	-variable ::agent_compare_complex
.m.settings add separator
# Keyboard behaviour clusters here: the editing mode decides what keys do inside
# the text area (D38), the shortcuts editor remaps the app chords (D23).
menu .m.settings.editmode -tearoff 0
.m.settings add cascade -label "Editing Mode" -menu .m.settings.editmode
.m.settings add checkbutton -label "Column Editing (Ctrl+Shift+Drag)" \
	-variable ::col_on -command apply_column_edit
.m.settings add command -label "Keyboard Shortcuts…" -command keybindings_dialog

# Extensions (D130) sits after Settings and before Help: rio's own configuration first,
# then what you have added to it, then Help last. It leads with the installer and then
# offers one door per installed extension that has something to configure — filled by
# extensions_menu_fill from the same cache the provider cascade above uses, so an
# extension appears here with no code change. The settings behind those doors belong to
# the extension; rio's settings ABOUT extensions stay in Preferences ▸ Extensions.
menu .m.extensions -tearoff 0
.m add cascade -label Extensions -menu .m.extensions
extensions_menu_fill

# Help is the last (rightmost) menu, the Windows/VSCode convention (D76). Contents… opens the
# manual in rio itself (D99) and About names the version and the build, so a tester can say
# which rio they're running (D123 — the release line, and the exact commit under it).
# Contents first, About last — the Windows order.
menu .m.help -tearoff 0
.m add cascade -label Help -menu .m.help
.m.help add command -label "Contents…" -command help_window
.m.help add separator
.m.help add command -label "About rio" -command about_dialog

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

# rio-gui/build.tcl — build the main window's widgets; top-level code, order matters.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

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

# rio-gui/build.tcl — build the main window's widgets; top-level code, order matters.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Build the UI. The colours and fonts here are placeholders: apply_theme sets
# every widget from the theme (D24).
# ---------------------------------------------------------------------------

# The dock sites (D35): left, right, bottom. Each is a tab strip (.tabs) over
# a body area (.body); the active panel's body is packed into it with -in.
# apply_layout drives them from ::layout. Propagation is off, so a site keeps
# its width when its tab changes.
foreach {_s _w} {left 220 right 340} {
	frame .site$_s -background "#dddddd" -width $_w
	pack propagate .site$_s 0
	frame .site$_s.tabs -background "#dddddd"
	frame .site$_s.body -background "#dddddd"
	pack .site$_s.tabs -side top -fill x
	pack .site$_s.body -side top -fill both -expand 1
}
# The bottom site keeps its height the same way.
frame .sitebottom -background "#dddddd" -height 160
pack propagate .sitebottom 0
frame .sitebottom.tabs -background "#dddddd"
frame .sitebottom.body -background "#dddddd"
pack .sitebottom.tabs -side top -fill x
pack .sitebottom.body -side top -fill both -expand 1

# The file pane (D42): a header over a sunken well holding a rich list, a
# read-only text widget. A text widget, because a listbox cannot draw
# coloured glyphs or full-width bands. Not a core buffer.
frame .pfiles -background "#dddddd"
# Its header: the project's name, ◉/◌ for hidden files (D62), ⟳ to refresh.
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
# The scrollbar is packed on demand (autoscroll). Double-click or Return
# opens a row; right-click shows the context menu.
rl_init .pfiles.well.body {} nav_open nav_context_menu
# D87: a single click on a folder's arrow unfolds it; a double-click on the
# name activates. These replace rl_init's click bindings on this body.
bind .pfiles.well.body <Button-1>        {nav_b1 %W %x %y ; break}
bind .pfiles.well.body <Double-Button-1> {nav_b1_double %W %x %y ; break}

# The git pane (D43): a branch header, the changed files (a rich list), and
# a read-only diff below.
frame .pgit -background "#dddddd"
frame .pgit.hdr -background "#dddddd"
label .pgit.hdr.branch -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .pgit.hdr.refresh -text "⟳" -font [chrome_font 9] -padx 6 \
	-background "#dddddd" -foreground black
# ↩ discards every change (D93). refresh_git packs it only while the repo
# has changes.
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
# -width 26, like the file pane: the default 80 columns would widen the dock.
text .pgit.diff -wrap none -width 26 -height 8 -state disabled \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black
ctx_bind_view .pgit.diff   ;# Copy / Select All (D115)
pack .pgit.well -side top -fill both -expand 1
pack .pgit.well.body -side left -fill both -expand 1
# Selecting a change shows its diff; right-click shows the context menu.
rl_init .pgit.well.body git_pick {} git_context_menu

# The commit bar (D45): a summary entry and a Commit button. refresh_git
# packs it only while something is staged. ＋ reveals a multi-line
# description (D80), which becomes the commit body.
set ::git_commit_body_shown 0
frame  .pgit.commit -background "#dddddd"
entry  .pgit.commit.msg  -font [chrome_font 9] -textvariable git_commit_msg
button .pgit.commit.more -text "＋" -font [chrome_font 9] -takefocus 0 -command git_commit_body_toggle
button .pgit.commit.go   -text "✓ Commit" -font [chrome_font 9] -command git_commit
text   .pgit.commit.body -height 4 -font [chrome_font 9] -wrap word -undo 1 \
	-borderwidth 1 -relief solid -highlightthickness 0
# A placeholder, shown while the entry is empty: a label placed inside the
# entry, so it is never part of `.msg get`. A trace hides it.
label .pgit.commit.msg.ph -text message -font [chrome_font 9] -takefocus 0 -borderwidth 0
place .pgit.commit.msg.ph -x 3 -rely 0.5 -anchor w
bind  .pgit.commit.msg.ph <Button-1> {focus .pgit.commit.msg}
# The body's own placeholder, same device — a child label over the text widget.
label .pgit.commit.body.ph -text "Longer description (optional)" -font [chrome_font 9] \
	-takefocus 0 -borderwidth 0
bind  .pgit.commit.body.ph <Button-1> {focus .pgit.commit.body}
# Context menus on both fields (D115). A right-click on a placeholder is
# forwarded to its field.
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
# Enter commits from the summary. In the body Enter is a newline, so
# Ctrl+Enter commits, from both fields. On a Mac ⌘Enter too (D136).
bind .pgit.commit.msg  <Return>         git_commit
foreach _m [lsort -unique [list Control $::primary_mod]] {
	bind .pgit.commit.msg  <$_m-Return> git_commit
	bind .pgit.commit.body <$_m-Return> {git_commit ; break}
}
unset _m

# The divider between the left site and the editor; dragging resizes the site.
frame .sash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .sash <B1-Motion> sash_drag
# On release the width is saved (D35).
bind .sash <ButtonRelease-1> { rio::layout::put left size [winfo width .siteleft] ; prefs_save }

# The divider above the bottom site; dragging resizes its height.
frame .bsash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .bsash <B1-Motion> bsash_drag
bind .bsash <ButtonRelease-1> { rio::layout::put bottom size [winfo height .sitebottom] ; prefs_save }

# The editor region (D33): a panedwindow with one or two editor groups side
# by side. make_editor_group builds a group.
panedwindow .groups -orient horizontal -borderwidth 0 \
	-sashwidth 6 -sashrelief raised -opaqueresize 1

# Resolve the keymap (defaults and keys.json) before any binding or menu.
keymap_resolve
set ::keymap_live_chords [keymap_chords] ;# what the first group's editor_bindings will bind

# The first editor group; a split adds the second.
make_editor_group 0
set ::groups {0}
set ::focus 0
relayout_groups

# The compare view (D28): two read-only panes with one shared scrollbar,
# shown in the centre in place of the editor. cmp_fill fills them from the
# core's diff.lines.
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
# A bar with the way out; the button names the Esc shortcut.
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

# The plan view (D101): a read-only pane in the centre, showing the agent's
# plan with the manual's renderer. Built like the compare view.
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

# The agent's chat pane:
#
#   ┌ Agent        Review ▾  Clear ┐
#   │ transcript                    │
#   ├───────────────────────────────┤   .chat.isash, draggable
#   │ input                         │
#   │ ▶ send                        │
#   └ provider · model ▾     busy ──┘
frame .chat -width 340 -background white
pack propagate .chat 0
frame .chat.hdr -background white
label .chat.hdr.title -text "Agent" -anchor w -font [chrome_font 9] -padx 4 -pady 2 \
	-background white -foreground black
label .chat.hdr.clear -text "Clear" -font [chrome_font 9] -padx 6 -cursor hand2 \
	-background white -foreground black
# The agent's mode (D102): Plan, Review or Auto.
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
# The same button is ■ stop while a turn runs (D104).
tooltip .chat.send "Send this message"
# The status strip: left, the provider and model as a control (D106); right,
# the working indicator.
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
# The divider between transcript and input; dragging sizes the input.
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
# "Plan" (plans only, D101): show the plan again after it was closed.
button .chat.approve.plan -text "Plan" -font [chrome_font 9] -command plan_reopen
# A plan is approved with a mode for the work that follows (D102): review
# each edit, or auto-accept.
menubutton .chat.approve.appr -text "Approve ▾" -font [chrome_font 9] \
	-menu .chat.approve.appr.m -relief raised -borderwidth 1 -padx 4
menu .chat.approve.appr.m -tearoff 0
.chat.approve.appr.m add command -label "Approve — review each edit" \
	-command {agent_decide_plan review}
.chat.approve.appr.m add command -label "Approve — auto-accept edits" \
	-command {agent_decide_plan auto}
# "Edit plan" (plans only, D102): the plan is a file; open it. Packed only
# when the plan was filed.
button .chat.approve.edit -text "Edit plan" -font [chrome_font 9] -command plan_edit
# "Always allow" (commands only, D84): add an allow rule. Its menu is rebuilt
# per proposal.
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

# The divider between the editor and the right site.
frame .csash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .csash <B1-Motion> csash_drag
bind .csash <ButtonRelease-1> { rio::layout::put right size [winfo width .siteright] ; prefs_save }

# The find bar (D36): hidden until find_open packs it above the status bar.
# Row 0 finds; row 1 replaces and is hidden in find-only mode.
frame .find -borderwidth 1 -relief raised -background "#dddddd"
label .find.fl -text "Find:"    -font [chrome_font 9] -anchor e -background "#dddddd"
label .find.rl -text "Replace:" -font [chrome_font 9] -anchor e -background "#dddddd"
entry .find.e  -font [chrome_font 11] -width 24
entry .find.re -font [chrome_font 11] -width 24
ctx_bind_input .find.e ; ctx_bind_input .find.re   ;# Cut / Copy / Paste / Select All (D115)
# ↓ and ↑ step through the matches; F3 and Shift+F3 by keyboard.
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
# Both entries: Enter steps, Shift+Enter steps back, Esc closes, F3 works.
# In the Replace entry Enter replaces.
foreach _w {.find.e .find.re} {
	bind $_w <Return>       {find_next ; break}
	bind $_w <Shift-Return> {find_prev ; break}
	bind $_w <Escape>       {find_close ; break}
	bind $_w <F3>           {find_next ; break}
	bind $_w <Shift-F3>     {find_prev ; break}
	# The search chord opens the Search panel with the bar's needle (D52).
	# Bound here: the editor's chord does not fire while an entry has focus.
	if {[set _c [key_chord search]] ne ""} { bind $_w <$_c> {search_from_bar ; break} }
}
bind .find.re <Return> {find_replace_one ; break}
bind .find.e  <KeyRelease> find_update
unset _w

# The Search panel (D52):
#
#   ┌ results (a rich list) ───────────────────────────────┐
#   ├ Replace: [      ] Replace All        (Ctrl+H toggles) ┤
#   └ Search: [      ] scope ▾  case  word  regex  count  × ┘
#
# The controls are at the bottom, like the chat's input: type below, read
# above. The scope menu picks Project, Open docs or Current doc.
frame .results -borderwidth 1 -relief raised -background "#dddddd"
frame .results.hdr -background "#dddddd"
label .results.hdr.l -text "Search:" -font [chrome_font 9] -background "#dddddd"
entry .results.hdr.e -font [chrome_font 11] -width 28
ctx_bind_input .results.hdr.e   ;# (D115)
# The scope menu sets ::search_scope; each entry re-runs the query.
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
# The replace row (D52), hidden until search_show_replace packs it above the
# query row.
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
# Double-click or Return on a match goes to it.
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

# Register the four panels, now that their bodies exist (D35).
rio::panel::register files  {title Files  site left   body .pfiles refresh populate_nav}
rio::panel::register git    {title Git    site left   body .pgit   refresh refresh_git}
rio::panel::register chat   {title Agent  site right  body .chat       refresh {}}
rio::panel::register search {title Search site bottom body .results    refresh search_run}

label .status -anchor w -font [chrome_font 9] -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
# apply_layout packs the sites and .groups at startup.
focus [gget 0 path]

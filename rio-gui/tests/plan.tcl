#!/usr/bin/env wish
#
# Headless plan-view test for rio-gui (AGENTS.md D101). In plan mode the agent may read and
# then say what it WOULD do, through the core's present_plan tool; the plan arrives as an
# agent.propose of kind `plan` carrying Markdown, and takes the center — where the compare
# view goes (D28) — rendered with the manual's renderer (D100), while the decision stays on
# the chat's Approve/Reject bar.
#
# The view is driven the way smoke.tcl drives the other proposal kinds: synthetic events
# straight into chat_event, which is the whole of the GUI's side of the contract. Checks:
# a plan proposal renders as blocks and takes the center; the bar asks the plan's question
# and offers Plan, not Compare or Always allow; Esc and a decision and a new message each
# put the editor back; reopening restores it; painting a plan does NOT cost an open manual
# page its anchors (the renderer's arrays are per widget); a theme change restyles it; and
# the mode toggle mirrors the core, including when the core flips it after an approval.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/plan.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII and the GUI's glyphs agree. The guard every entry point carries (D54).
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
set ::connect_to "127.0.0.1:$::port"
set argv {}
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}

# A plan with one of everything the renderer knows, so "it rendered" means more than "text
# arrived": a heading, a list, a table and a fenced block.
set ::md "## Context

The search re-reads every file on **each** keystroke.

- memoize it
- invalidate on `fs.changed`

| file | change |
| ---- | ------ |
| project.tcl | a cache |

```
proc search {} {}
```
"
proc plan_event {{turn 1} {id p1} {title "Add a cache"} {path .rio/plans/20260911-120000-add-a-cache.md}} {
	chat_event [list event agent.propose params [list turn $turn id $id name present_plan \
		kind plan title $title plan $::md path $path]]
}

# --- a plan takes the center and renders as a document -------------------------------
plan_event
set t .plan.text
ok "open: the plan view is the center"  $::plan_shown 1
ok "open: the editor is not packed"     [expr {[lsearch [pack slaves .] .groups] >= 0}] 0
ok "open: and the plan pane is"         [expr {[lsearch [pack slaves .] .plan] >= 0}] 1
ok "render: headings are painted"       [expr {[llength [$t tag ranges h2]] > 0}] 1
ok "render: the list is painted"        [expr {[llength [$t tag ranges li0]] > 0}] 1
ok "render: the table is painted"       [expr {[llength [$t tag ranges table]] > 0}] 1
ok "render: the code block is painted"  [expr {[llength [$t tag ranges code]] > 0}] 1
ok "render: inline markup is painted"   [expr {[llength [$t tag ranges strong]] > 0}] 1
ok "render: the source is not shown"    [string first "**each**" [$t get 1.0 end]] -1
ok "render: the pane is read-only"      [$t cget -state] disabled
ok "header: names the plan"             [string match "Plan — Add a cache*" [.plan.hdr cget -text]] 1
ok "header: and where it was filed"     [string match "*.rio/plans/*add-a-cache.md" [.plan.hdr cget -text]] 1

# The chat keeps the trace and the decision; the bar asks the plan's own question, and
# offers Plan (reopen) but neither Compare (there is no diff) nor Always allow (there is no
# allow-list for a plan).
ok "chat: the trace names the plan"     [expr {[string first "presents a plan: Add a cache" [.chat.log get 1.0 end]] >= 0}] 1
ok "chat: and where it was saved"       [expr {[string first "saved as .rio/plans/" [.chat.log get 1.0 end]] >= 0}] 1
ok "bar: shown"                         [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 1
ok "bar: asks about the plan"           [.chat.approve.lbl cget -text] "Start work on this plan?"
ok "bar: offers Plan"                   [expr {[lsearch [pack slaves .chat.approve] .chat.approve.plan] >= 0}] 1
ok "bar: no Compare"                    [expr {[lsearch [pack slaves .chat.approve] .chat.approve.cmp] >= 0}] 0
ok "bar: no Always allow"               [expr {[lsearch [pack slaves .chat.approve] .chat.approve.always] >= 0}] 0
ok "bar: the turn is pending"           $::pending_turn 1

# --- closing and reopening ------------------------------------------------------------
plan_close
ok "close: the editor is back"          $::plan_shown 0
ok "close: .groups packed again"        [expr {[lsearch [pack slaves .] .groups] >= 0}] 1
plan_reopen
ok "reopen: the plan is back"           $::plan_shown 1
ok "reopen: still rendered"             [expr {[llength [$t tag ranges h2]] > 0}] 1

# One center at a time: opening a plan while comparing takes the compare view's place.
set ::compare_shown 1 ; set ::plan_shown 0 ; apply_layout
plan_event 2 p2 "Second plan"
ok "center: the plan replaces compare"  [list $::plan_shown $::compare_shown] {1 0}
ok "center: only the plan is packed"    [expr {[lsearch [pack slaves .] .cmp] >= 0}] 0

# --- the renderer is shared, and does not tread on the manual -------------------------
# help_paint keys its anchor/link arrays per widget, so a plan painted while the help
# window is open must leave that page's anchors — the targets of its own #slug links —
# exactly where they were.
help_window preferences.md
help_goto preferences.md#where-everything-lives
set ::before [lsort [array names ::help_anchor .help.page.text,*]]
set ::scrolled [expr {[lindex [.help.page.text yview] 0] > 0}]
plan_event 3 p3 "While help is open"
ok "shared: the manual keeps its anchors" [lsort [array names ::help_anchor .help.page.text,*]] $::before
ok "shared: it had some to keep"          [expr {[llength $::before] > 3}] 1
ok "shared: its own anchor still resolves" [help_anchor_see where-everything-lives] 1
ok "shared: which had scrolled the page"   $::scrolled 1
ok "shared: the plan got its own anchors"  [info exists ::help_anchor(.plan.text,context)] 1
destroy .help

# --- a decision, and a new message, each dismiss the review --------------------------
# agent_decide is the Approve/Reject path: the bar goes, the plan view goes, the core is
# told. The core here is a real one over the socket, so approving a turn it has never
# heard of is an error the GUI swallows — what matters is the view state afterwards.
plan_event 4 p4
agent_decide approve
ok "decide: the bar is gone"            [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 0
ok "decide: the plan view is gone"      $::plan_shown 0
ok "decide: nothing is pending"         $::pending_turn ""

plan_event 5 p5
.chat.input insert end "never mind, do something else"
chat_send
ok "send: an abandoned plan is dismissed" $::plan_shown 0
ok "send: and its bar with it"           [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 0

# Clearing the conversation aborts the turn in the core, so the review UI is asking about a
# decision nothing waits for — it goes too, rather than leaving the whole center occupied.
plan_event 6 p6
chat_clear
ok "clear: the plan view goes too"      $::plan_shown 0
ok "clear: and the bar"                 [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 0

# --- theming ---------------------------------------------------------------------------
# The plan view outlives a theme change like the help window does: apply_theme calls
# plan_restyle, which dresses the chrome and re-runs the shared renderer styling.
plan_event 6 p6
do_theme solarized-dark
ok "theme: the pane follows the theme"  [$t cget -background] [dict get $::theme_colors editor.bg]
ok "theme: the header follows too"      [.plan.hdr cget -background] [dict get $::theme_colors ui.bg]
ok "theme: headings keep their tag"     [expr {[llength [$t tag ranges h2]] > 0}] 1
do_theme default
ok "theme: and back"                    [$t cget -background] [dict get $::theme_colors editor.bg]
plan_close

# --- the bar is where the user says how the work goes (D102) ---------------------------
# A plan is not approved into a policy set before it was written: the two ways to say yes
# are on the bar, under the plan the user has just read.
proc bar_slaves {} { return [pack slaves .chat.approve] }
plan_event 7 p7
ok "bar: Approve is a menubutton"       [winfo class .chat.approve.appr] Menubutton
ok "bar: with two ways to say yes"      [expr {[.chat.approve.appr.m index end] + 1}] 2
ok "bar: the plain Approve is not shown" [expr {[lsearch [bar_slaves] .chat.approve.yes] >= 0}] 0
ok "bar: offers Edit plan"              [expr {[lsearch [bar_slaves] .chat.approve.edit] >= 0}] 1
ok "bar: still offers Reject"           [expr {[lsearch [bar_slaves] .chat.approve.no] >= 0}] 1
# A plan with no project behind it was filed nowhere — there is no file to edit.
plan_event 8 p8 "Nowhere to file it" ""
ok "bar: an unfiled plan has nothing to edit" [expr {[lsearch [bar_slaves] .chat.approve.edit] >= 0}] 0
# An edit proposal is unchanged by all this: Approve/Reject/Compare, no plan controls.
approve_bar 1
ok "bar: an edit keeps its plain Approve" [expr {[lsearch [bar_slaves] .chat.approve.yes] >= 0}] 1
ok "bar: and shows no Approve menu"       [expr {[lsearch [bar_slaves] .chat.approve.appr] >= 0}] 0
ok "bar: and its Compare"                 [expr {[lsearch [bar_slaves] .chat.approve.cmp] >= 0}] 1
approve_bar 0

# Approving with a policy is two things in order: the core's auto-accept flag, then the
# decision. Picking "review each edit" is just as explicit — it turns auto-accept OFF.
rio_result agent.autoaccept.set {on 0}
plan_event 9 p9
agent_decide_plan auto
ok "approve auto: the core is auto-accepting" [dict get [rio_result agent.status {}] auto_accept] 1
ok "approve auto: the GUI agrees"             $::agent_auto_accept 1
ok "approve auto: the turn was decided"       $::pending_turn ""
ok "approve auto: the plan view is gone"      $::plan_shown 0
plan_event 10 p10
agent_decide_plan review
ok "approve review: auto-accept is off"       [dict get [rio_result agent.status {}] auto_accept] 0
ok "approve review: the GUI agrees"           $::agent_auto_accept 0

# --- editing a plan ---------------------------------------------------------------------
# The plan is a file in the project, so "edit it" is rio's ordinary edit path: the view
# steps out of the center and the plan opens as a buffer. The turn stays pending — the
# next thing is still to approve.
set ::tf [file tempfile ::tpath] ; close $::tf
set ::proj [file join [file dirname $::tpath] riogui-plan-[clock clicks]]
file mkdir [file join $::proj .rio plans]
set ::pfile [file join $::proj .rio plans 20260911-120000-edit-me.md]
set fh [open $::pfile w] ; puts $fh "# Edit me\n\n- as written by the model" ; close $fh
open_folder $::proj
plan_event 11 p11 "Edit me" .rio/plans/20260911-120000-edit-me.md
plan_edit
ok "edit: the plan view steps aside"    $::plan_shown 0
ok "edit: the plan is open as a buffer" [bufget $::cur path] [file normalize $::pfile]
ok "edit: the turn is still pending"    $::pending_turn 11
ok "edit: and the bar is still up"      [expr {[lsearch [pack slaves .chat] .chat.approve] >= 0}] 1
# Reopening repaints from the plan as it stands now — the edit is what gets approved, so
# the edit is what the view must show.
.ed.t insert "end-1c" "\n## Added by the user\n"
plan_reopen
ok "reopen: the user's edit is rendered" \
	[expr {[string first "Added by the user" [$t get 1.0 end]] >= 0}] 1
ok "reopen: rendered, not dumped"       [expr {[llength [$t tag ranges h2]] > 0}] 1
agent_decide reject
chat_busy_stop   ;# agent_decide restarts the working animation, which owns the strip
sandbox_drop_fixture $::proj

# --- the mode is one control, and it mirrors the core -----------------------------------
# ::agent_mode_ui is DERIVED from the core's two flags; every door writes through
# agent_mode_set, so no two doors can disagree.
set ::agent_mode_ui plan ; agent_mode_set
ok "mode: the core is in plan mode"     [dict get [rio_result agent.status {}] mode] plan
ok "mode: the control says Plan"        [.chat.hdr.mode cget -text] "Plan ▾"
ok "mode: the strip names the provider only" [.chat.status.sel cget -text] "Echo ▾"
set ::agent_mode_ui auto ; agent_mode_set
ok "mode: auto turns the core's flag on" [dict get [rio_result agent.status {}] auto_accept] 1
ok "mode: and leaves build mode"         [dict get [rio_result agent.status {}] mode] build
ok "mode: the control says Auto"         [.chat.hdr.mode cget -text] "Auto ▾"
# jka's ruling: picking Plan does NOT clear auto-accept behind the user's back. The label
# is honest without it — while planning, nothing is being edited at all, and how the work
# goes afterwards is asked on the plan's own bar.
set ::agent_mode_ui plan ; agent_mode_set
ok "mode: plan leaves auto-accept alone" [dict get [rio_result agent.status {}] auto_accept] 1
ok "mode: and still reads Plan"          [.chat.hdr.mode cget -text] "Plan ▾"
set ::agent_mode_ui review ; agent_mode_set
ok "mode: review turns the flag off"     [dict get [rio_result agent.status {}] auto_accept] 0
ok "mode: and the control says Review"   [.chat.hdr.mode cget -text] "Review ▾"

# Every door is the same door: the Settings cascade and the Preferences radios drive the
# same variable through the same writer as the header control.
ok "doors: Settings drives ::agent_mode_ui" \
	[.m.settings.agentmode entrycget 0 -variable] ::agent_mode_ui
ok "doors: through the same writer"      [.m.settings.agentmode entrycget 0 -command] agent_mode_set
ok "doors: three states, not two toggles" [expr {[.m.settings.agentmode index end] + 1}] 3

# The core flips the mode itself when a plan is approved, and announces it — the control
# has to follow, or it would claim the agent is planning while it edits.
set ::agent_plan_mode 1 ; agent_mode_sync
chat_event {event agent.mode params {mode build}}
ok "mode: an agent.mode event is adopted" $::agent_plan_mode 0
ok "mode: and the control relabelled"     [.chat.hdr.mode cget -text] "Review ▾"

# adopt_agent_status reads the mode back from whatever core the GUI attached to (D30) —
# a daemon someone else put in plan mode must not be silently switched by our boot default.
rio_result agent.mode.set {mode plan}
set ::agent_plan_mode 0
adopt_agent_status
ok "adopt: the core's mode wins"        $::agent_plan_mode 1
ok "adopt: and the control with it"     [.chat.hdr.mode cget -text] "Plan ▾"
rio_result agent.mode.set {mode build}

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

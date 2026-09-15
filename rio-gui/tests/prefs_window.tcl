#!/usr/bin/env wish
#
# Headless test for the Preferences window (AGENTS.md D58). The window owns no state:
# each control drives the SAME global its menu twin binds and calls the SAME applier, so
# it is live-apply and the two doors stay in sync for free. Checks that the window opens
# with its five categories, that toggling a control there flips the global AND matches
# the menu entry's -variable (the two-door sync), that changing the tab layout re-flows
# the strip, that the category switch selects, that opening twice is safe, and that the
# theme/mode radios are enumerated from the core/registry.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/prefs_window.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows); this file's own
# non-ASCII expectations (the … glyphs, theme labels) then arrive mojibake. Re-source
# under UTF-8 — the same guard every entry point carries; a test file is one too. No-op
# where the system encoding is already UTF-8.
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
# A fresh core buffer, registered in group 0 under a chosen display name.
proc mkbuf {name} {
	set id [dict get [rio_result buffer.new {}] buffer]
	register_buffer $id "/proj/$name" {} 0
	return $id
}

# --- the window opens with its five categories ------------------------------------
preferences_window
update idletasks
ok "window exists"               [winfo exists .prefs]                 1
ok "five categories"             [.prefs.cats size]                    5
ok "view body exists"            [winfo exists .prefs.body.view]       1
ok "editor body exists"          [winfo exists .prefs.body.editor]     1
ok "agent body exists"           [winfo exists .prefs.body.agent]      1
ok "extensions body exists"      [winfo exists .prefs.body.extensions] 1
ok "keyboard body exists"        [winfo exists .prefs.body.keyboard]   1

# The Extensions category (D107): the start-up update check is the one durable
# decision about repositories, so it lives here, in the config home — and it is OFF
# by default, because a fresh rio makes no network request it wasn't asked to make.
ok "update check exists"         [winfo exists .prefs.body.extensions.chk] 1
ok "update check is off"         $::ext_check_updates                  0
ok "update check binds the flag" [.prefs.body.extensions.chk cget -variable] ::ext_check_updates

# --- two-door sync: the window control binds the SAME global the menu entry does ---
ok "wrap: same var as menu"      [.prefs.body.view.wrap cget -variable] \
                                 [.m.view entrycget "Wrap Lines" -variable]
ok "tabs: same var as menu"      [.prefs.body.view.mtab cget -variable] \
                                 [.m.view entrycget "Multi-Line Tabs" -variable]

# --- toggling a control in the window flips the live global (and so the editor) ----
set w0 $::wrap_lines
.prefs.body.view.wrap invoke
ok "wrap: window toggles global" [expr {$::wrap_lines != $w0}]         1
.prefs.body.view.wrap invoke
ok "wrap: toggles back"          $::wrap_lines                         $w0

# --- changing the tab layout from the window re-flows the strip --------------------
set a [mkbuf pref-doc-a.txt] ; set b [mkbuf pref-doc-b.txt]
refresh_tabs ; update idletasks
set ::tab_layout scroll ; tab_layout_apply
.prefs.body.view.mtab invoke          ;# -> multi
ok "tabs: window set multi"      $::tab_layout                         multi
ok "tabs: strip re-flowed packed" [winfo manager [gget 0 tabs].b$a]    pack
.prefs.body.view.mtab invoke          ;# -> back to scroll
ok "tabs: window set scroll"     $::tab_layout                         scroll

# --- the category switch selects, and prefs_show_cat is safe with a selection ------
.prefs.cats selection clear 0 end
.prefs.cats selection set 1
prefs_show_cat .prefs
ok "category: selects editor"    [.prefs.cats get [.prefs.cats curselection]] Editor

# --- the theme control is a button onto the shared picker, showing the current label ----
# It was a dropdown until D92; a menu can't bound its own height and the theme list grows
# with every installed theme, so both doors now go through pick_dialog.
ok "view: theme is a button"     [winfo class .prefs.body.view.theme]  Button
ok "view: no dropdown menu left" [winfo exists .prefs.body.view.theme.m] 0
ok "view: it opens the picker"   [.prefs.body.view.theme cget -command] theme_pick_dialog
ok "view: rows come from core"   [expr {[llength [theme_pick_rows]] > 1}] 1
ok "view: row is {name label}"   [llength [lindex [theme_pick_rows] 0]]  2
# The button text is the pretty label plus an ellipsis (the "opens a chooser" affordance);
# it tracks ::theme_choice, so a switch from either door updates it.
ok "view: ellipsis on the label" [string match "*…" $::theme_choice_label] 1
ok "view: label tracks choice"   [string match "[theme_label $::theme_choice]*" $::theme_choice_label] 1
set _was $::theme_choice
do_theme [lindex [lindex [theme_pick_rows] 0] 0]
ok "view: pick sets label" \
	[string match "[theme_label [lindex [lindex [theme_pick_rows] 0] 0]]*" $::theme_choice_label] 1
do_theme $_was
ok "view: Font has a heading"    [winfo exists .prefs.body.view.fontl]  1

# --- editing-mode radios are enumerated (not hard-coded) ---------------------------
ok "editor: mode radios built"   [winfo exists .prefs.body.editor.em1] 1
ok "editor: windows is a mode"   [expr {"windows" in [rio::modes::names]}] 1

# --- Agent pane: the prompts + allow-list doors + the echo-only hint ----------------
# The Agent pane is now the ONLY door to the agent's heavier config: the Settings menu
# keeps just the provider picker and the two quick toggles, so keys/prompts/allow-list
# live here (jka, 2026-09-09). With only the echo stub registered (this test's core
# installs no provider) a muted hint points at Extensions… for a real model.
ok "agent: prompts button present" [winfo exists .prefs.body.agent.prompts] 1
ok "agent: allow button present"   [winfo exists .prefs.body.agent.allow]   1
ok "agent: echo-only hint present" [winfo exists .prefs.body.agent.hint]    1
.prefs.body.agent.prompts invoke
ok "agent: prompts button opens it" [winfo exists .agentprompts]            1
destroy .agentprompts

# The mode is three exclusive states, not two independent checkboxes (D102) — two
# checkboxes could show "plan mode" with auto-accept quietly armed behind it. Same
# variable and same writer as the chat header's control and the Settings cascade.
foreach v {plan review auto} {
	ok "agent: $v is a radio"        [winfo class .prefs.body.agent.m$v]     Radiobutton
	ok "agent: $v shares the state"  [.prefs.body.agent.m$v cget -variable]  ::agent_mode_ui
	ok "agent: $v uses the writer"   [.prefs.body.agent.m$v cget -command]   agent_mode_set
}
ok "agent: no plan-mode checkbox"   [winfo exists .prefs.body.agent.pm]      0
ok "agent: no auto-accept checkbox" [winfo exists .prefs.body.agent.aa]      0
# Picking one here reaches the core, like every other control in this window (live-apply).
.prefs.body.agent.mplan invoke
ok "agent: the core is planning"    [dict get [rio_result agent.status {}] mode] plan
.prefs.body.agent.mreview invoke
ok "agent: and back to building"    [dict get [rio_result agent.status {}] mode] build

# https without host-name checks (D110): a checkbox whose truth is the core's, off by
# default, written to the core's agent.conf (the sandboxed XDG dir here) and mirrored back.
set tlsconf [file join $::env(XDG_CONFIG_HOME) rio agent agent.conf]
proc tlsconf_says {path} {
	if {![file exists $path]} { return absent }
	set fh [open $path] ; set t [read $fh] ; close $fh
	return [expr {[regexp {tls_unchecked_hostnames = (\w+)} $t -> v] ? $v : "unset"}]
}
ok "tls: checkbox present"          [winfo class .prefs.body.agent.tls]      Checkbutton
ok "tls: off by default"            $::agent_tls_unchecked                   0
ok "tls: the core agrees"           [dict get [rio_result agent.status {}] tls_unchecked] 0
ok "tls: hint present"              [winfo exists .prefs.body.agent.tlshint] 1
.prefs.body.agent.tls invoke
ok "tls: on reaches the core"       [dict get [rio_result agent.status {}] tls_unchecked] 1
ok "tls: the box shows it"          $::agent_tls_unchecked                   1
ok "tls: stored in agent.conf"      [tlsconf_says $tlsconf]                   allow
.prefs.body.agent.tls invoke
ok "tls: off reaches the core"      [dict get [rio_result agent.status {}] tls_unchecked] 0
ok "tls: stored as refuse"          [tlsconf_says $tlsconf]                   refuse
# Another frontend (or a hand edit) changed it: attaching again mirrors the core, not the box.
rio_result agent.tls.set {unchecked 1}
adopt_agent_status
ok "tls: adopt mirrors the core"    $::agent_tls_unchecked                   1
rio_result agent.tls.set {unchecked 0}
adopt_agent_status

# --- opening twice reuses the window rather than erroring --------------------------
ok "reopen: no second toplevel"  [catch {preferences_window}]          0
ok "reopen: window still there"  [winfo exists .prefs]                 1

# --- the Settings menu carries the entry point, keyboard default unbound -----------
ok "menu: Preferences in Settings" [.m.settings type "Preferences…"]   command
ok "keymap: default unbound"     [lindex [dict get $::keymap_default preferences] 0] ""
# The agent config dialogs moved OUT of the Settings menu into this window; the menu
# keeps only the provider picker + quick toggles (jka, 2026-09-09).
ok "menu: no Agent API Key cascade"  [catch {.m.settings index "Agent API Key"}] 1
ok "menu: no Agent Prompts entry"    [catch {.m.settings index "Agent Prompts…"}] 1
ok "menu: no Allowed commands entry" [catch {.m.settings index "Agent: Allowed commands…"}] 1
ok "menu: provider picker stays"     [.m.settings type "Agent Provider"]   cascade
# The mode is a cascade of the same three states, not the old pair of checkbuttons (D102).
ok "menu: Agent Mode is a cascade"   [.m.settings type "Agent Mode"]        cascade
ok "menu: no Plan mode checkbutton"  [catch {.m.settings index "Agent: Plan mode"}] 1
ok "menu: no auto-accept checkbutton" [catch {.m.settings index "Agent: Auto-accept edits"}] 1

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

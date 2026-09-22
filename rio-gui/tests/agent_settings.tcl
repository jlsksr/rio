#!/usr/bin/env wish
#
# Headless test for the provider settings window (provider-api 4). The window renders
# whatever the provider DECLARES — a chooser, a field, a section heading — and knows
# nothing about what any of it means, which is the D106 discipline one level up. So the
# provider here is a fake whose options are deliberately not "model" and "effort": if a
# check passes only because the window recognised a familiar name, that is a bug.
#
# Covers: the door in Preferences ▸ Agent, one control per declared option, grouping and
# order, a chooser writing through the core, a field writing on Return and on a DIRTY
# focus-out but not a clean one, a refusal landing in the status line with the field put
# back, a window open on a NON-ACTIVE provider repainting from its own agent.options
# event (the bug the two-surface split fixed), and the close/reopen path.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/agent_settings.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows); this file's own
# non-ASCII expectations (the … and ▾ glyphs) then arrive mojibake. Re-source under
# UTF-8 — the same guard every entry point carries. No-op where it is already UTF-8.
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

# --- a fake provider, declaring one of every kind ----------------------------
#
# It lives in the core this suite started, so everything below travels the real channel:
# the window's reads and writes are ops, exactly as they would be against a core on
# another machine.
namespace eval vend {
	variable model   alpha
	variable url     http://127.0.0.1:1080/v1
	variable cap     4096
	variable mood    calm
	variable refreshed 0
}
proc vend::provider {conversation tools system post} { {*}$post done stop }
proc vend::opts {} {
	variable model ; variable url ; variable cap ; variable mood
	return [list \
		[dict create name model label Model group Model value $model free 1 refresh 1 \
			hint "Which model answers." \
			choices {{value alpha label Alpha} {value beta label Beta}}] \
		[dict create name mood label Mood group Model value $mood quick 0 \
			choices {{value calm label Calm} {value wild label Wild}}] \
		[dict create name base_url label "Base URL" group Server kind text value $url \
			hint "Where the server lives."] \
		[dict create name cap label "Max tokens" group Server kind number value $cap]]
}
proc vend::opt_set {name value} {
	variable model ; variable url ; variable cap ; variable mood
	switch -- $name {
		model    { set model $value }
		mood     { set mood $value }
		cap {
			if {![string is integer -strict $value] || $value <= 0} {
				rio::error::raise bad_request "max tokens must be a positive whole number"
			}
			set cap $value
		}
		base_url {
			# Canonicalizes, so the window has to show what the PROVIDER made of the
			# value rather than what was typed.
			set url [string trimright [string trim $value] /]
		}
		default { rio::error::raise bad_request "unknown option: $name" }
	}
	return
}
proc vend::opt_refresh {name announce} {
	variable refreshed
	incr refreshed
	{*}$announce
	return
}
rio::agent::register_provider vend ::vend::provider -label "Vendorless" \
	-options [dict create list ::vend::opts set ::vend::opt_set refresh ::vend::opt_refresh]

# A second one that declares nothing, so the door is offered on merit and not to all.
namespace eval mute {}
proc mute::provider {conversation tools system post} { {*}$post done stop }
rio::agent::register_provider mute ::mute::provider -label "Muted"

agent_providers_refresh

# --- the door ----------------------------------------------------------------
preferences_window
.prefs.cats selection clear 0 end
.prefs.cats selection set 2      ;# Agent
prefs_show_cat .prefs
update idletasks

proc prefs_buttons {} {
	set out {}
	foreach ch [winfo children .prefs.body.agent] {
		if {[winfo class $ch] eq "Button"} { lappend out [$ch cget -text] }
	}
	return $out
}
set ::btns [prefs_buttons]
ok "door: a provider with options gets a settings button" \
	[expr {"Vendorless settings…" in $::btns}] 1
ok "door: one without options does not" \
	[expr {"Muted settings…" in $::btns}] 0
ok "door: the flag comes from the core, not a guess" \
	[list [provider_has_options vend] [provider_has_options mute]] {1 0}

# --- the form ----------------------------------------------------------------
provider_settings_dialog vend
update idletasks
ok "window: exists"            [winfo exists .provset]      1
ok "window: names the provider" [wm title .provset]         "Vendorless settings"
ok "window: is NOT modal"      [grab current .provset]      ""
ok "window: knows who it shows" $::provset_provider         vend

# One control per option, in declaration order, with the group headings between.
proc form_rows {} {
	set out {}
	foreach ch [lsort -dictionary [winfo children .provset.body]] {
		set t [winfo name $ch]
		if {[string match l* $t] || [string match g* $t]} {
			lappend out [list [string index $t 0] [$ch cget -text]]
		}
	}
	return $out
}
ok "form: a label for every option" \
	[llength [lsearch -all -index 0 [form_rows] l]] 4
ok "form: a heading per group, once each" \
	[llength [lsearch -all -index 0 [form_rows] g]] 2
ok "form: the field kinds became the right controls" \
	[list [winfo class .provset.body.c1.mb] [winfo class .provset.body.c3]] {Menubutton Entry}
ok "form: a quick-0 choice is still IN the window" \
	[winfo exists .provset.body.c2.mb] 1
ok "form: a refreshable option offers a refresh beside it" \
	[winfo exists .provset.body.c1.rf] 1
ok "form: a non-refreshable one does not" \
	[winfo exists .provset.body.c3.rf] 0
ok "form: a field shows the current value" [.provset.body.c3 get] http://127.0.0.1:1080/v1
ok "form: a chooser shows the current label" \
	[string match "Alpha*" [.provset.body.c1.mb cget -text]] 1
ok "form: a hint is rendered where declared" \
	[.provset.body.h3 cget -text] "Where the server lives."

# --- writing -----------------------------------------------------------------
provider_settings_write vend model beta
update idletasks
ok "write: a chooser reaches the core"  [set ::vend::model] beta
ok "write: and the form follows"        [string match "Beta*" [.provset.body.c1.mb cget -text]] 1
ok "write: the status line says so"     [.provset.status cget -text] "Saved."

# A field commits through provider_settings_field. Headless, .provset is a transient of
# a withdrawn root and so never mapped, and a generated <Return> is not delivered to an
# unmapped window — so the handler is driven directly and the BINDING that would call it
# is asserted separately, which is how rio tests every other key path headlessly (D23).
ok "write: Return is bound to the field committer" \
	[string match "*provider_settings_field*" [bind .provset.body.c3 <Return>]] 1
ok "write: and so is FocusOut" \
	[string match "*provider_settings_field*" [bind .provset.body.c3 <FocusOut>]] 1
ok "write: the field carries the D115 context menu" \
	[string match "*ctx_menu_post*" [bind .provset.body.c3 <Button-3>]] 1

.provset.body.c3 delete 0 end
.provset.body.c3 insert 0 "http://box.local:8080/v1"
provider_settings_field .provset.body.c3 vend base_url
update idletasks
ok "write: a field commits"   [set ::vend::url] "http://box.local:8080/v1"

# Only when it differs — a focus-out fires on every tab-through and on the way to Close,
# and a write per glance would be a round-trip and a status line claiming a save that
# never happened.
provider_settings_status ""
provider_settings_field .provset.body.c3 vend base_url
update idletasks
ok "write: an unchanged field writes nothing" [.provset.status cget -text] ""

# What the window shows is what the PROVIDER accepted, not what was typed.
.provset.body.c3 delete 0 end
.provset.body.c3 insert 0 "http://trailing.local/v1///"
provider_settings_field .provset.body.c3 vend base_url
update idletasks
ok "write: a canonicalized value is what comes back" [set ::vend::url] "http://trailing.local/v1"
ok "write: and the field is rewritten to it" [.provset.body.c3 get] "http://trailing.local/v1"

# A refusal: the status line, never a modal — and the field goes back to the core's value.
.provset.body.c4 delete 0 end
.provset.body.c4 insert 0 "lots"
provider_settings_field .provset.body.c4 vend cap
update idletasks
ok "write: a refusal reaches the status line" \
	[string match "*positive whole number*" [.provset.status cget -text]] 1
ok "write: and it never opened a dialog"      [llength $::headless_dialogs] 0
ok "write: the field is put back to the core's value" [.provset.body.c4 get] 4096

# --- the non-active provider, which is the bug this split fixed --------------
#
# The strip only ever shows the ACTIVE provider, so the agent.options event used to be
# ignored for any other one — and ⟳ Refresh in a window open on that other provider did
# nothing at all, silently.
ok "remote: the window is not showing the active provider" \
	[expr {$::agent_provider ne "vend"}] 1
set ::vend::refreshed 0
set ::vend::model alpha        ;# changed behind the window's back, as a refresh would
agent_option_fetch model vend
for {set i 0} {$i < 50 && [set ::vend::refreshed] == 0} {incr i} { update ; after 10 }
ok "remote: the refresh reached the provider" [set ::vend::refreshed] 1
for {set i 0} {$i < 50 && ![string match "Alpha*" [.provset.body.c1.mb cget -text]]} {incr i} {
	update ; after 10
}
ok "remote: and its event repainted a window that is not the active provider's" \
	[string match "Alpha*" [.provset.body.c1.mb cget -text]] 1
ok "remote: writing there did not disturb the active provider" $::agent_provider echo

# An error on that event lands in the window's status line, not in a dialog.
provider_settings_status ""
chat_event [dict create event agent.options params [dict create provider vend error "the server said no"]]
for {set i 0} {$i < 50 && [.provset.status cget -text] eq ""} {incr i} { update ; after 10 }
ok "remote: a refresh failure lands in the window" \
	[.provset.status cget -text] "the server said no"
ok "remote: and not in a dialog" [llength $::headless_dialogs] 0

# The same failure with no window open has nowhere to go but a dialog — the old path,
# still there for the strip.
destroy .provset
update idletasks
ok "close: the window forgets which provider it showed" $::provset_provider ""
ok "close: and a repaint for it is a no-op"  [provider_settings_showing vend] 0

# --- reopening ---------------------------------------------------------------
provider_settings_dialog vend
update idletasks
ok "reopen: opens again"              [winfo exists .provset] 1
ok "reopen: shows the stored values"  [.provset.body.c3 get] "http://trailing.local/v1"
provider_settings_dialog vend         ;# twice: raises, never stacks a second toplevel
update idletasks
ok "reopen: opening twice is safe"    [winfo exists .provset] 1
provider_settings_dialog mute         ;# a provider with nothing to declare
update idletasks
ok "reopen: switching provider retitles" [wm title .provset] "Muted settings"
ok "reopen: and says there is nothing to set" \
	[winfo exists .provset.body.none] 1
destroy .provset
destroy .prefs

puts [expr {$::fails ? "$::fails CHECK(S) FAILED" : "ALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

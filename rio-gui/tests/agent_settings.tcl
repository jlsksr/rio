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

# A third that declares NO options but does take a key — the case D130's door predicate
# exists for: its key is the one thing it has to set, and gating on options alone would
# leave it with nowhere to set it.
namespace eval vault {
	variable key ""
}
proc vault::provider {conversation tools system post} { {*}$post done stop }
proc vault::set_key   {k} { variable key ; set key $k ; return }
proc vault::clear_key {}  { variable key ; set key "" ; return }
proc vault::configured {} { variable key ; return [expr {$key ne ""}] }
rio::agent::register_provider vault ::vault::provider -label "Vaulted" \
	-signup vault.example \
	-key [dict create set ::vault::set_key clear ::vault::clear_key \
		status ::vault::configured]

agent_providers_refresh

# --- the door ----------------------------------------------------------------
#
# A menu entry, not a button in rio's own Preferences (D130): what a provider lets you
# configure is the provider's business, so it gets its own window and the Extensions
# menu lists whoever has one. Rebuilt from the cache, so a provider registered above
# appears with no code change — which is the whole claim.
extensions_menu_fill

proc ext_menu_labels {} {
	set out {}
	for {set i 0} {$i <= [.m.extensions index end]} {incr i} {
		if {[catch {.m.extensions entrycget $i -label} l]} continue
		lappend out $l
	}
	return $out
}
set ::extm [ext_menu_labels]
ok "door: the menu leads with the installer" [lindex $::extm 0] "Extensions…"
ok "door: a provider with options gets a door" \
	[expr {"Vendorless…" in $::extm}] 1
ok "door: a keyed provider with no options gets one too" \
	[expr {"Vaulted…" in $::extm}] 1
ok "door: one with nothing at all to set does not" \
	[expr {"Muted…" in $::extm}] 0
ok "door: the options flag comes from the core, not a guess" \
	[list [provider_has_options vend] [provider_has_options mute]] {1 0}
ok "door: and the door predicate counts the key as well" \
	[list [provider_has_settings vend] [provider_has_settings vault] \
		[provider_has_settings mute]] {1 1 0}
ok "door: the entry opens that provider's window" \
	[.m.extensions entrycget [.m.extensions index "Vaulted…"] -command] \
	{provider_settings_dialog vault}

# The rows are merged from wherever they come from, not read off the provider list: a
# GUI-side extension (a mode, later) registers one and it lands in the same menu.
ext_settings_register zzmode "Zed Mode" {puts zed}
extensions_menu_fill
ok "door: a GUI-side extension can register a door too" \
	[expr {"Zed Mode…" in [ext_menu_labels]}] 1
proc ext_row_labels {} {
	set out {}
	foreach row [ext_settings_rows] { lappend out [lindex $row 1] }
	return $out
}
ok "door: rows are sorted by label" \
	[ext_row_labels] [lsort -dictionary [ext_row_labels]]
set ::ext_settings_extra {}

# D92: no menu in rio is data-driven and unbounded. Past the cap this one becomes the
# same bounded picker Switch to Tab… and Theme… use, rather than a list on a stick.
#
# Tested at the BOUNDARY, and the count is padded up to it rather than driven by it: a
# loop that runs ::ext_settings_menu_max times always overshoots whatever that is, so it
# would pass just as happily with the cap raised to a million or deleted outright.
ok "cap: the bound is small enough to be a menu" \
	[expr {$::ext_settings_menu_max > 0 && $::ext_settings_menu_max <= 20}] 1
proc pad_rows_to {n} {
	set ::ext_settings_extra {}
	set have [llength [ext_settings_rows]]
	for {set i $have} {$i < $n} {incr i} { ext_settings_register pad$i "Padding $i" {} }
	extensions_menu_fill
}
pad_rows_to $::ext_settings_menu_max
ok "cap: at the limit they are still listed one by one" \
	[list [llength [ext_settings_rows]] [expr {"Vendorless…" in [ext_menu_labels]}] \
		[expr {"Extension settings…" in [ext_menu_labels]}]] \
	[list $::ext_settings_menu_max 1 0]
pad_rows_to [expr {$::ext_settings_menu_max + 1}]
ok "cap: one past it, the list collapses to a picker" \
	[expr {"Extension settings…" in [ext_menu_labels]}] 1
ok "cap: and stops listing them one by one" \
	[expr {"Vendorless…" in [ext_menu_labels]}] 0
set ::ext_settings_extra {}
extensions_menu_fill
ok "cap: under it, they are listed again" \
	[expr {"Vendorless…" in [ext_menu_labels]}] 1

# --- the credentials group ----------------------------------------------------
#
# The key is a row in the provider's own window now, not a modal of its own (D130), so
# a provider's window holds everything that belongs to it. rio never reads a stored key
# back, so the field is always blank and the note says whether one is there.
provider_settings_dialog vault
update idletasks
ok "key: the field is there"     [winfo exists .provset.body.keye]        1
ok "key: and it is masked"       [.provset.body.keye cget -show]          "•"
ok "key: nothing to clear yet"   [.provset.body.keyb.clear cget -state]   "disabled"
ok "key: the note says so"       [.provset.body.keyn cget -text] \
	"No key stored yet. Create one at vault.example."
ok "key: an empty save is refused" [list [provider_key_field_save vault] \
	[::vault::configured]] {{} 0}
ok "key: and says why, in the window" \
	[expr {[string match "Enter an API key*" [.provset.status cget -text]]}] 1
.provset.body.keye insert 0 " sk-secret "
provider_key_field_save vault
update idletasks
ok "key: a save reaches the provider, trimmed" \
	[list [::vault::configured] [set ::vault::key]] {1 sk-secret}
ok "key: the window says so"     [.provset.status cget -text]             "Key saved."
ok "key: the note flips"         [.provset.body.keyn cget -text] \
	"A key is stored; saving one replaces it. Create one at vault.example."
ok "key: and Clear comes alive"  [.provset.body.keyb.clear cget -state]   "normal"
ok "key: the field is never filled back in" [.provset.body.keye get]      ""
ok "key: Show key unmasks"       [list [set ::provider_key_show 1] \
	[provider_key_field_reveal] [.provset.body.keye cget -show]] {1 {} {}}
provider_key_field_clear vault
update idletasks
ok "key: Clear reaches the provider" [::vault::configured]                0
ok "key: the window says so"     [.provset.status cget -text]             "Key removed."
ok "key: and Clear goes back to disabled" [.provset.body.keyb.clear cget -state] "disabled"
ok "key: a provider with no key gets no such row" \
	[list [provider_settings_dialog vend] [update idletasks] \
		[winfo exists .provset.body.keye]] {{} {} 0}
ok "key: and no dialog was ever opened for any of it" $::headless_dialogs {}
destroy .provset

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

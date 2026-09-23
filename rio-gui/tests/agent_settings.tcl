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

# A fourth that keeps PROFILES and declares an option whose value names a file (D131).
# Again deliberately unfamiliar: its option is not "model" and not "extra request JSON",
# so nothing below can pass by recognising a shipped provider's vocabulary. The storage
# is the core's own (rio::agent::settings), so these tests drive the real files.
namespace eval atlas {
	variable region north
	variable charts ""
	variable profile ""
	variable defaults {region north charts ""}
}
proc atlas::provider {conversation tools system post} { {*}$post done stop }
proc atlas::opts {} {
	variable region ; variable charts
	return [list \
		[dict create name region label Region group Where value $region free 1 \
			choices {{value north label North} {value south label South}}] \
		[dict create name charts label Charts group Where kind text file 1 quick 0 \
			hint "A file of extra charts." value $charts]]
}
proc atlas::opt_set {name value} {
	variable region ; variable charts ; variable profile
	switch -- $name {
		region { set region $value }
		charts { set charts $value }
		default { rio::error::raise bad_request "unknown option: $name" }
	}
	rio::agent::settings::store atlas $name $value $profile
	return
}
proc atlas::opt_file {name} {
	variable charts
	if {$name ne "charts"} { rio::error::raise bad_request "option '$name' names no file" }
	if {$charts eq ""} { opt_set charts "$::atlas::profile.charts" }
	set p [file join [rio::agent::settings::profile_dir atlas] $charts]
	set created 0
	if {![file isfile $p]} {
		file mkdir [file dirname $p]
		set fh [open $p w 0600] ; puts -nonewline $fh "" ; close $fh
		set created 1
	}
	return [dict create path $p created $created]
}
proc atlas::_adopt {} {
	variable region ; variable charts ; variable profile ; variable defaults
	set region [rio::agent::settings::get atlas region [dict get $defaults region] $profile]
	set charts [rio::agent::settings::get atlas charts [dict get $defaults charts] $profile]
}
proc atlas::prof_list {} {
	variable profile
	return [dict create profiles [rio::agent::settings::profiles atlas] active $profile]
}
proc atlas::prof_switch {name} {
	variable profile
	if {![rio::agent::settings::profile_exists atlas $name]} {
		rio::error::raise bad_request "no such profile: $name"
	}
	set profile $name
	_adopt
	return $name
}
proc atlas::prof_add {name {from ""}} {
	rio::agent::settings::profile_add atlas $name $from
	return $name
}
proc atlas::prof_remove {name} {
	variable profile
	if {[llength [rio::agent::settings::profiles atlas]] <= 1} {
		rio::error::raise bad_request "'$name' is the only profile"
	}
	rio::agent::settings::profile_remove atlas $name
	if {$name eq $profile} { prof_switch [lindex [rio::agent::settings::profiles atlas] 0] }
	return $name
}
proc atlas::prof_rename {name to} {
	variable profile
	rio::agent::settings::profile_rename atlas $name $to
	if {$name eq $profile} { set profile $to }
	return $to
}
rio::agent::register_provider atlas ::atlas::provider -label "Atlas" \
	-options [dict create list ::atlas::opts set ::atlas::opt_set \
		file ::atlas::opt_file] \
	-profiles [dict create list ::atlas::prof_list switch ::atlas::prof_switch \
		add ::atlas::prof_add remove ::atlas::prof_remove rename ::atlas::prof_rename]
atlas::prof_add Home
atlas::prof_add Away
atlas::prof_switch Home

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
ok "door: the menu leads with the installer" [lindex $::extm 0] "Browse…"
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

# --- profiles (D131) ---------------------------------------------------------
#
# The row, the manager and the strip menu — all rendered from what the provider declares
# and what the core answers, so none of it names atlas, a region or a charts file.

proc profrow {} { return .provset.body.profc }

provider_settings_dialog atlas
update idletasks
ok "profiles: the provider declares them"     [provider_has_profiles atlas] 1
ok "profiles: and one that doesn't, doesn't"  [provider_has_profiles vend] 0
ok "profiles: the row is drawn"               [winfo exists [profrow]] 1
# ...and only for a provider that keeps them. A row with nothing to put in it would be
# worse than none: it would claim a choice that does not exist.
provider_settings_dialog vend
update idletasks
ok "profiles: no row without them"            [winfo exists [profrow]] 0
provider_settings_dialog atlas
update idletasks
ok "profiles: it names the active profile"    [[profrow].mb cget -text] "Home ▾"
ok "profiles: and offers every one"           [[profrow].mb.m index end] 1

# The row sits ABOVE the credentials and every declared option: it decides what they all
# show, so it cannot be read last.
ok "profiles: the row comes first" \
	[expr {[lindex [grid info .provset.body.profh] [expr {[lsearch [grid info .provset.body.profh] -row]+1}]] < \
	       [lindex [grid info .provset.body.l1]   [expr {[lsearch [grid info .provset.body.l1] -row]+1}]]}] 1

# Switching from the row reaches the core and the form repaints from it.
provider_profile_switch atlas Away
update idletasks
ok "profiles: switching reaches the core"     [rio::agent::profile_name atlas] Away
ok "profiles: the row follows"                [[profrow].mb cget -text] "Away ▾"

# A setting made in one profile stays there — the reason profiles exist, checked through
# the window rather than in the core's own tests.
provider_settings_write atlas region south
update idletasks
provider_profile_switch atlas Home
update idletasks
ok "profiles: a setting does not follow you"  [set ::atlas::region] north
provider_profile_switch atlas Away
update idletasks
ok "profiles: and is there when you go back"  [set ::atlas::region] south
provider_profile_switch atlas Home
update idletasks

# --- the manager -------------------------------------------------------------
provider_profiles_dialog atlas
update idletasks
ok "manage: the dialog opens"                 [winfo exists .provprof] 1
ok "manage: it lists every profile"           $::provprof_names {Away Home}
ok "manage: and marks the active one"         [.provprof.body.list get 1] "● Home"
ok "manage: with it selected"                 [.provprof.body.list curselection] 1

# Switch from the manager.
.provprof.body.list selection clear 0 end
.provprof.body.list selection set 0
provprof_use
update idletasks
ok "manage: Switch to reaches the core"       [rio::agent::profile_name atlas] Away
ok "manage: and the list re-marks it"         [.provprof.body.list get 0] "● Away"

# New — created AND switched to, because making one and not going to it is never what a
# person meant.
rename name_prompt _real_np
proc name_prompt {title label prefill} { return $::np_answer }
set ::np_answer "Field"
provprof_new
update idletasks
ok "manage: New creates it"                   [expr {"Field" in $::provprof_names}] 1
ok "manage: and switches to it"               [rio::agent::profile_name atlas] Field
ok "manage: at the provider's defaults"       [set ::atlas::region] north

# Duplicate — from the selected profile, so it starts with that one's settings.
.provprof.body.list selection clear 0 end
.provprof.body.list selection set [lsearch $::provprof_names Away]
set ::np_answer "Away copy"
provprof_dup
update idletasks
ok "manage: Duplicate copies the settings"    [set ::atlas::region] south
ok "manage: under the new name"               [rio::agent::profile_name atlas] "Away copy"

# Rename — the pointer follows when it is the active one.
set ::np_answer "Far"
.provprof.body.list selection clear 0 end
.provprof.body.list selection set [lsearch $::provprof_names "Away copy"]
provprof_rename
update idletasks
ok "manage: Rename renames"                   [expr {"Far" in $::provprof_names}] 1
ok "manage: and the active pointer follows"   [rio::agent::profile_name atlas] Far
rename name_prompt {} ; rename _real_np name_prompt

# Delete — the one destructive verb, so the one that asks.
rename tk_messageBox _real_mb
proc tk_messageBox {args} { set ::mb_asked [dict get $args -message] ; return $::mb_answer }
set ::mb_asked "" ; set ::mb_answer no
.provprof.body.list selection clear 0 end
.provprof.body.list selection set [lsearch $::provprof_names Field]
provprof_delete
update idletasks
ok "manage: Delete asks first"                [string match "*Field*" $::mb_asked] 1
ok "manage: and No deletes nothing"           [expr {"Field" in $::provprof_names}] 1
set ::mb_answer yes
.provprof.body.list selection clear 0 end
.provprof.body.list selection set [lsearch $::provprof_names Field]
provprof_delete
update idletasks
ok "manage: Yes deletes it"                   [expr {"Field" in $::provprof_names}] 0
rename tk_messageBox {} ; rename _real_mb tk_messageBox

# A refusal from the provider lands in the settings window's status line, never a modal
# (which a headless run would fail outright — D95).
ok "manage: still more than one left"         [expr {[llength $::provprof_names] > 1}] 1
destroy .provprof
update idletasks

# --- an option that names a file ---------------------------------------------
#
# The value is a name; the button opens the file the CORE resolved — so a remote core
# opens its own disk, which is the whole reason this is an op and not a path join here.
provider_settings_dialog atlas
update idletasks
set ::charts_ctl ""
foreach child [winfo children .provset.body] {
	if {[string match .provset.body.c* $child] && [winfo exists $child.ed]} {
		set ::charts_ctl $child
	}
}
ok "file: the flagged option gets a field and a button" \
	[expr {$::charts_ctl ne "" && [winfo exists $::charts_ctl.e]}] 1
ok "file: the button says Edit…"              [$::charts_ctl.ed cget -text] "Edit…"
ok "file: an ordinary field gets no button" \
	[winfo exists .provset.body.c1.ed] 0

$::charts_ctl.ed invoke
update idletasks
# Not a buffer COUNT: opening a file while the only tab is an empty scratch reuses it,
# so the count is unchanged and the question is whether the right path is open.
set paths {}
foreach id [dict keys $::buffers] { lappend paths [dict get $::buffers $id path] }
set want [dict get [rio::agent::option_file charts atlas] path]
ok "file: it opens the core's own path as a tab" [expr {$want in $paths}] 1
ok "file: and it is the focused tab"          [dict get $::buffers $::cur path] $want
ok "file: the provider recorded a name for it" [expr {[set ::atlas::charts] ne ""}] 1
# Naming none was the ordinary case, so the field it just filled in has to show it.
ok "file: and the field shows it"             [$::charts_ctl.e get] [set ::atlas::charts]
destroy .provset

# --- the chat strip's Profile section ----------------------------------------
#
# Switching a profile is a fast switch, so it belongs in the menu (D85); MAKING one is
# not, and stays in the window.
rio_call agent.provider.set [dict create name atlas]
set ::agent_provider atlas
agent_options_refresh
update idletasks
proc strip_labels {} {
	set out {}
	for {set i 0} {$i <= [.chat.status.sel.m index end]} {incr i} {
		if {[catch {.chat.status.sel.m entrycget $i -label} l]} continue
		lappend out [string trim $l]
	}
	return $out
}
set labels [strip_labels]
ok "strip: the menu has a Profile section"    [expr {"Profile" in $labels}] 1
ok "strip: listing every profile"             [expr {"Far" in $labels && "Home" in $labels}] 1
ok "strip: the tooltip names the live one" \
	[string match "*Profile: *" $::tt_text(.chat.status.sel)] 1
# ...but the 340 px label does not: the model already answers "what am I talking to",
# and a profile name can be long.
ok "strip: the label stays short"             [string match "*Profile:*" [.chat.status.sel cget -text]] 0
set was [rio::agent::profile_name atlas]
agent_profile_pick Home
update idletasks
ok "strip: picking one reaches the core"      [rio::agent::profile_name atlas] Home
ok "strip: and it really changed"             [expr {$was ne "Home"}] 1

# A provider with no profiles gets no section — the same merit test as the door.
rio_call agent.provider.set [dict create name vend]
set ::agent_provider vend
agent_options_refresh
update idletasks
ok "strip: no section for a provider without profiles" \
	[expr {"Profile" in [strip_labels]}] 0

puts [expr {$::fails ? "$::fails CHECK(S) FAILED" : "ALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]

# rio-gui/agent.tcl — the agent's provider, key, profiles, options, mode and allow-list.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The agent's provider (D26). One provider runs at a time: `echo`, the
# offline default, or an installed one, which usually needs an API key. The
# core runs the provider and stores its key (D21). The chat names the active
# provider.
# ---------------------------------------------------------------------------
set ::agent_provider echo   ;# echo | claude | openai | …
set ::provider_key_show 0   ;# the key field's reveal toggle (the provider settings window)
# The Agent Prompts dialog's provider chooser (D79) and its button label.
set ::agent_prompt_provider ""
set ::agent_prompt_provider_label ""
# The providers the core carries, from agent.providers (D30). The picker and
# the key field are built from this list, so a newly installed provider needs
# no GUI change. Seeded, so the menus have a label before the core answers.
set ::agent_providers {{name echo label Echo keyed 0 key_set 0 signup {}}}

# Pull the core's provider list into the cache (agent.providers, D30).
proc agent_providers_refresh {} {
	set resp [rio_call agent.providers {}]
	if {[dict get $resp ok]} { set ::agent_providers [dict get $resp result providers] }
}

# A provider's cache entry by name, or "" if unknown.
proc agent_provider_entry {name} {
	foreach p $::agent_providers { if {[dict get $p name] eq $name} { return $p } }
	return ""
}

# A provider's display label, or its title-cased name before the cache is filled.
proc agent_provider_label {name} {
	set p [agent_provider_entry $name]
	return [expr {$p ne "" ? [dict get $p label] : [string totitle $name]}]
}

# A picker label: "Claude (API key)", "Echo (offline)".
proc provider_radio_label {p} {
	return "[dict get $p label] ([expr {[dict get $p keyed] ? {API key} : {offline}}])"
}

# Tell the core which provider to run (agent.provider.set, D30). Only from a
# user action, never at attach time: see adopt_agent_status.
proc apply_provider {} {
	rio_result agent.provider.set [dict create name $::agent_provider]
	agent_options_refresh   ;# a different provider offers different choices
	chat_status_update
}

# --- the live agent: provider, model, effort, as one control (D106) -----------
#
# What a provider lets you choose is the provider's business. The core hands
# over the options it declares and this code draws whatever is in the list.
# Nothing below names a model or an effort.
set ::agent_options {}           ;# the active provider's options, as the core declared them
array set ::agent_option_value {} ;# option name -> chosen value, for the menu's radios
set ::agent_profiles {profiles {} active ""}  ;# the active provider's profiles (D131)
set ::agent_profile  ""          ;# the live one, for the menu's radios and the tooltip

# Fetch the active provider's options and repaint the control.
proc agent_options_refresh {} {
	set r [rio_call agent.options.list {}]
	set ::agent_options [expr {[dict get $r ok] ? [dict get $r result options] : {}}]
	# And its profiles (D131); empty for a provider without any.
	set ::agent_profiles [provider_profiles $::agent_provider]
	set ::agent_profile  [dict get $::agent_profiles active]
	agent_options_sync
}

# One option's descriptor by name, or "".
proc agent_option_entry {name} {
	foreach o $::agent_options { if {[dict get $o name] eq $name} { return $o } }
	return ""
}

# Which control an option wants: choice, text or number (provider-api 4). An
# unknown kind becomes `choice` if there are choices, else `text`, so a newer
# provider still gets a control.
proc agent_option_kind {o} {
	set k [expr {[dict exists $o kind] ? [dict get $o kind] : "choice"}]
	if {$k in {choice text number}} { return $k }
	return [expr {[llength [dict get $o choices]] ? "choice" : "text"}]
}

# Does this option belong in the chat strip's menu too? The provider says
# whether it is `quick`; the GUI says whether a menu can draw it: only a
# choice.
proc agent_option_quick {o} {
	if {[dict exists $o quick] && ![dict get $o quick]} { return 0 }
	return [expr {[agent_option_kind $o] eq "choice"}]
}

# The options the strip may show, for its label and for its menu.
proc agent_options_strip {} {
	set out {}
	foreach o $::agent_options { if {[agent_option_quick $o]} { lappend out $o } }
	return $out
}

# A value's label, falling back to the value itself (a free value the list never had).
proc agent_option_label {o value} {
	foreach c [dict get $o choices] {
		if {[dict get $c value] eq $value} { return [dict get $c label] }
	}
	return $value
}

# Repaint the selector: "Claude · opus · high ▾".
# - The first option the strip may show is always named: it is the model.
# - Another option is named only when it is not at its default.
# - The tooltip names every option, and the profile.
proc agent_options_sync {} {
	if {![winfo exists .chat.status.sel]} return
	# Every option's value, quick or not: the settings window binds them too.
	foreach o $::agent_options {
		set ::agent_option_value([dict get $o name]) [dict get $o value]
	}
	set parts [list [agent_provider_label $::agent_provider]]
	set first 1
	foreach o [agent_options_strip] {
		set v [dict get $o value]
		if {$first || ![agent_option_is_default $o]} { lappend parts [agent_option_label $o $v] }
		set first 0
	}
	set full [list "Provider: [agent_provider_label $::agent_provider]"]
	if {$::agent_profile ne ""} { lappend full "Profile: $::agent_profile" }
	foreach o $::agent_options {
		set v [dict get $o value]
		lappend full "[dict get $o label]: [agent_option_label $o $v] ($v)"
	}
	.chat.status.sel configure -text "[join $parts { · }] ▾"
	tooltip .chat.status.sel [join $full "\n"]
	agent_options_menu_fill
}

# Is an option at its default? By convention the first choice is the default.
proc agent_option_is_default {o} {
	set cs [dict get $o choices]
	if {![llength $cs]} { return 0 }
	return [expr {[dict get $o value] eq [dict get [lindex $cs 0] value]}]
}

# Build the selector's menu: the providers (the same radios and writer as
# Settings and Preferences), the profiles, then one section per option.
proc agent_options_menu_fill {} {
	if {![winfo exists .chat.status.sel.m]} return
	set m .chat.status.sel.m
	$m delete 0 end
	$m add command -label "Provider" -state disabled
	foreach p $::agent_providers {
		$m add radiobutton -label "   [provider_radio_label $p]" \
			-variable ::agent_provider -value [dict get $p name] -command apply_provider
	}
	# The profiles, if there are several (D131), above the options they decide.
	if {[llength [dict get $::agent_profiles profiles]] > 1} {
		$m add separator
		$m add command -label "Profile" -state disabled
		foreach p [dict get $::agent_profiles profiles] {
			$m add radiobutton -label "   $p" \
				-variable ::agent_profile -value $p \
				-command [list agent_profile_pick $p]
		}
	}
	# Only quick choices; the rest is in the settings window.
	foreach o [agent_options_strip] {
		set n [dict get $o name]
		$m add separator
		$m add command -label [dict get $o label] -state disabled
		foreach c [dict get $o choices] {
			$m add radiobutton -label "   [dict get $c label]" \
				-variable ::agent_option_value($n) -value [dict get $c value] \
				-command [list agent_option_pick $n [dict get $c value]]
		}
		if {[dict get $o free]} {
			$m add command -label "   Other…" -command [list agent_option_other $n]
		}
		if {[dict get $o refresh]} {
			$m add command -label "   ⟳ Refresh from provider" \
				-command [list agent_option_fetch $n]
		}
	}
}

# Write one option. Returns "" on success, else the core's message. No
# dialog: the settings window shows a refusal in its status line.
# `provider` "" means the active one.
proc agent_option_write {provider name value} {
	set p [dict create name $name value $value]
	if {$provider ne ""} { dict set p provider $provider }
	set resp [rio_call agent.option.set $p]
	if {[dict get $resp ok]} { return "" }
	return [dict get $resp error message]
}

# Repaint what shows this provider's options: the chat strip (the active
# provider only) and the settings window.
proc agent_options_repaint {provider} {
	if {$provider eq "" || $provider eq $::agent_provider} { agent_options_refresh }
	provider_settings_repaint $provider
}

# Push a choice to the core, then read back: the menu then shows what the
# provider accepted, or after a refusal what it still has.
proc agent_option_pick {name value {provider ""}} {
	set err [agent_option_write $provider $name $value]
	if {$err ne ""} { report_error $err }
	agent_options_repaint $provider
}

# Switch the active provider's profile from the strip: push, then read back.
proc agent_profile_pick {to} {
	set resp [rio_call agent.profile.set [dict create name $to]]
	if {![dict get $resp ok]} { report_error [dict get $resp error message] }
	agent_options_repaint $::agent_provider
}

# Enter a value the list lacks, e.g. a newer model. Only for a `free` option.
proc agent_option_other {name {provider ""} {o ""}} {
	if {$o eq ""} { set o [agent_option_entry $name] }
	if {$o eq ""} return
	set v [name_prompt "[dict get $o label]" "Enter a [string tolower [dict get $o label]]:" \
		[dict get $o value]]
	if {$v eq "" || $v eq [dict get $o value]} return
	agent_option_pick $name $v $provider
}

# Ask the provider to re-fetch an option's choices. The new list arrives as
# an agent.options event.
proc agent_option_fetch {name {provider ""}} {
	set p [dict create name $name]
	if {$provider ne ""} { dict set p provider $provider }
	rio_result agent.options.refresh $p
}

# --- the provider settings window (provider-api 4) ---------------------------
#
# A provider's full configuration: a form built from what the provider
# declares (D106). Opened from the Extensions menu (D130).
# - Not modal: it repaints on the agent.options event, which a grab would hold.
# - No OK or Cancel: each field is written when it is committed (D58).
set ::provset_provider ""   ;# which provider .provset is showing, "" = closed

# Is the settings window open on this provider?
proc provider_settings_showing {provider} {
	return [expr {[winfo exists .provset] && $provider ne "" \
		&& $provider eq $::provset_provider}]
}

# Does this provider declare options? From the cached list: no round trip.
proc provider_has_options {name} {
	foreach p $::agent_providers {
		if {[dict get $p name] eq $name} {
			return [expr {[dict exists $p options] && [dict get $p options]}]
		}
	}
	return 0
}

# Does this provider keep profiles (D131)? From the cached list.
proc provider_has_profiles {name} {
	foreach p $::agent_providers {
		if {[dict get $p name] eq $name} {
			return [expr {[dict exists $p profiles] && [dict get $p profiles]}]
		}
	}
	return 0
}

# Has this provider anything to configure? A key counts, not only options
# (D130): a keyed provider without options still needs its key field.
proc provider_has_settings {name} {
	set p [agent_provider_entry $name]
	if {$p eq ""} { return 0 }
	return [expr {[dict get $p keyed] || [provider_has_options $name]}]
}

# --- a provider's profiles, in the settings window (D131) --------------------
#
# A profile has a name; one is active; four verbs act on them.

# A provider's profiles from the core: {profiles {…} active <name>}.
proc provider_profiles {name} {
	set r [rio_call agent.profiles.list [dict create provider $name]]
	if {![dict get $r ok]} { return [dict create profiles {} active ""] }
	set out {}
	foreach p [dict get $r result profiles] { lappend out [dict get $p name] }
	return [dict create profiles $out active [dict get $r result active]]
}

# Run one profile op. A refusal goes to the status line. The form is rebuilt
# from the core, so it shows what the provider did. Returns 1 on success.
proc provider_profile_do {op name params} {
	set resp [rio_call $op [dict merge [dict create provider $name] $params]]
	if {![dict get $resp ok]} {
		provider_settings_status [dict get $resp error message] 1
		return 0
	}
	provider_settings_repaint $name
	if {$name eq $::agent_provider} { agent_options_refresh }
	return 1
}

proc provider_profile_switch {name to} {
	if {[provider_profile_do agent.profile.set $name [dict create name $to]]} {
		provider_settings_status "Switched to “$to”."
	}
}

# New (the provider's defaults) or, with `from`, Duplicate.
proc provider_profile_new {name {from ""}} {
	set what [expr {$from eq "" ? "New profile" : "Duplicate profile"}]
	set to [name_prompt $what "Name for the new profile:" \
		[expr {$from eq "" ? "" : "$from copy"}]]
	if {$to eq ""} return
	set params [dict create name $to]
	if {$from ne ""} { dict set params from $from }
	if {[provider_profile_do agent.profile.add $name $params]} {
		# A new profile is switched to at once.
		provider_profile_switch $name $to
	}
}

proc provider_profile_rename {name old} {
	set to [name_prompt "Rename profile" "New name for “$old”:" $old]
	if {$to eq "" || $to eq $old} return
	if {[provider_profile_do agent.profile.rename $name [dict create name $old to $to]]} {
		provider_settings_status "Renamed to “$to”."
	}
}

# Delete asks first; the default is No (D48).
proc provider_profile_delete {name victim} {
	set ans [tk_messageBox -parent .provset -icon warning -type yesno -default no \
		-title "Delete profile" \
		-message "Delete the profile “$victim”?" \
		-detail "Its settings, and any extra-request file of its own, are removed. This cannot be undone."]
	if {$ans ne "yes"} return
	if {[provider_profile_do agent.profile.remove $name [dict create name $victim]]} {
		provider_settings_status "Deleted “$victim”."
	}
}

# The profile manager, modal over the settings window. It reads the list
# again after every verb.
proc provider_profiles_dialog {name} {
	set w .provprof
	destroy $w
	toplevel $w
	wm title $w "Profiles — [agent_provider_label $name]"
	wm transient $w .provset
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set ::provprof_provider $name

	grid [prefs_hint $w.hint \
		"Each profile keeps its own settings and its own API key. Switching between them changes what the agent runs on; nothing here is shared." 380] \
		-row 0 -column 0 -columnspan 2 -sticky w -padx 8 -pady {8 6}
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.provprof.body.list yview}
	listbox $w.body.list -activestyle none -exportselection 0 -height 8 -width 34 \
		-font RioUIFont -yscrollcommand {.provprof.body.sb set} \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg] \
		-highlightthickness 1 -relief solid -borderwidth 1
	pack $w.body.sb -side right -fill y
	pack $w.body.list -side left -fill both -expand 1
	grid $w.body -row 1 -column 0 -sticky nsew -padx {8 4} -pady {0 6}

	frame $w.btns -background [dict get $c ui.bg]
	foreach {b label cmd} {
		use    "Switch to"  provprof_use
		new    "New…"       provprof_new
		dup    "Duplicate…" provprof_dup
		ren    "Rename…"    provprof_rename
		del    "Delete…"    provprof_delete
	} {
		button $w.btns.$b -text $label -font RioUIFont -width 12 -command $cmd
		pack $w.btns.$b -side top -pady 2 -fill x
	}
	grid $w.btns -row 1 -column 1 -sticky n -padx {0 8} -pady {0 6}

	frame $w.foot -background [dict get $c ui.bg]
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.close -side right
	grid $w.foot -row 2 -column 0 -columnspan 2 -sticky we -padx 8 -pady {0 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> provprof_use
	bind $w <Escape> [list destroy $w]
	provprof_fill
	focus $w.body.list
	grab $w
}

# Repaint the list from the core, with the active profile selected.
proc provprof_fill {} {
	if {![winfo exists .provprof]} return
	set r [provider_profiles $::provprof_provider]
	set active [dict get $r active]
	.provprof.body.list delete 0 end
	set i 0
	foreach p [dict get $r profiles] {
		.provprof.body.list insert end [expr {$p eq $active ? "● $p" : "   $p"}]
		if {$p eq $active} { .provprof.body.list selection set $i }
		incr i
	}
	set ::provprof_names [dict get $r profiles]
	set ::provprof_active $active
}

# The selected profile's name, or "". Taken from ::provprof_names: the row's
# label carries a marker.
proc provprof_selected {} {
	if {![winfo exists .provprof]} { return "" }
	set s [.provprof.body.list curselection]
	if {$s eq ""} { return "" }
	return [lindex $::provprof_names [lindex $s 0]]
}

proc provprof_use {} {
	set n [provprof_selected]
	if {$n eq "" || $n eq $::provprof_active} return
	provider_profile_switch $::provprof_provider $n
	provprof_fill
}
proc provprof_new    {} { provider_profile_new $::provprof_provider ; provprof_fill }
proc provprof_dup    {} {
	set n [provprof_selected]
	if {$n eq ""} return
	provider_profile_new $::provprof_provider $n
	provprof_fill
}
proc provprof_rename {} {
	set n [provprof_selected]
	if {$n eq ""} return
	provider_profile_rename $::provprof_provider $n
	provprof_fill
}
proc provprof_delete {} {
	set n [provprof_selected]
	if {$n eq ""} return
	provider_profile_delete $::provprof_provider $n
	provprof_fill
}

proc provider_settings_dialog {name} {
	set w .provset
	if {[winfo exists $w] && $::provset_provider eq $name} {
		wm deiconify $w ; raise $w ; return
	}
	destroy $w
	set ::provset_provider $name
	toplevel $w
	wm title $w "[agent_provider_label $name] settings"
	wm transient $w [expr {[winfo exists .prefs] ? ".prefs" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -wraplength 460 -font RioUIFont \
		-text "Everything that belongs to this provider: its credentials and the settings it declares. All of it is stored on the machine the core runs on. A declared field takes effect when you press Return or leave it; the API key waits for its Save button." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	label $w.status -anchor w -justify left -wraplength 460 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	grid $w.hint   -row 0 -column 0 -sticky we   -padx 8 -pady {8 6}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.status -row 2 -column 0 -sticky we   -padx 8 -pady {6 0}
	grid $w.btns   -row 3 -column 0 -sticky we   -padx 8 -pady {4 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	provider_settings_fill
	bind $w <Escape>  [list destroy $w]
	bind $w <Destroy> [list provider_settings_closed %W]
	focus $w.btns.close
}

# <Destroy> fires for every descendant too; only the toplevel's counts.
proc provider_settings_closed {which} {
	if {$which eq ".provset"} { set ::provset_provider "" }
}

proc provider_settings_status {text {bad 0}} {
	if {![winfo exists .provset.status]} return
	set c $::theme_colors
	.provset.status configure -text $text \
		-foreground [dict get $c [expr {$bad ? "error" : "gutter.fg"}]]
}

# The provider's API key (D130). The core stores it and never returns it
# (D21), so the field is always blank and a note says whether one is stored.
# Written only by Save, not on focus-out. Returns the advanced row counter.
proc provider_settings_credentials {body name r} {
	set c $::theme_colors
	set p [agent_provider_entry $name]
	set stored [expr {$p ne "" && [dict get $p key_set]}]
	grid [prefs_label $body.keyh "Credentials"] -row [incr r] -column 0 \
		-columnspan 2 -sticky w -pady {0 2}
	grid [prefs_label $body.keyl "API key:"] -row [incr r] -column 0 -sticky w -padx {12 6}
	entry $body.keye -show • -font RioUIFont -width 44 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-highlightthickness 1 -relief solid -borderwidth 1
	ctx_bind_input $body.keye   ;# masked, so Cut/Copy are left out (D115)
	bind $body.keye <Return> [list provider_key_field_save $name]
	grid $body.keye -row $r -column 1 -sticky we
	frame $body.keyb -background [dict get $c ui.bg]
	set ::provider_key_show 0
	checkbutton $body.keyb.show -text "Show key" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -selectcolor [dict get $c ui.bg] \
		-variable ::provider_key_show -command provider_key_field_reveal
	button $body.keyb.save  -text "Save"  -font RioUIFont \
		-command [list provider_key_field_save $name]
	button $body.keyb.clear -text "Clear" -font RioUIFont \
		-command [list provider_key_field_clear $name] \
		-state [expr {$stored ? "normal" : "disabled"}]
	pack $body.keyb.show $body.keyb.save $body.keyb.clear -side left -padx {0 6}
	grid $body.keyb -row [incr r] -column 1 -sticky w -pady {2 0}
	set note [expr {$stored ? "A key is stored; saving one replaces it." : "No key stored yet."}]
	set signup [expr {$p ne "" ? [dict get $p signup] : ""}]
	if {$signup ne ""} { append note " Create one at $signup." }
	grid [prefs_hint $body.keyn $note 420] -row [incr r] -column 1 -sticky w -pady {0 2}
	return $r
}

# The Profile row (D131): switch here, manage with Manage…. Returns the
# advanced row counter.
proc provider_settings_profile_row {body name r} {
	set c $::theme_colors
	set pr [provider_profiles $name]
	set active [dict get $pr active]
	grid [prefs_label $body.profh "Profile"] -row [incr r] -column 0 \
		-columnspan 2 -sticky w -pady {0 2}
	grid [prefs_label $body.profl "Profile:"] -row [incr r] -column 0 -sticky w -padx {12 6}
	frame $body.profc -background [dict get $c ui.bg]
	menubutton $body.profc.mb -anchor w -relief raised -borderwidth 1 -padx 6 -pady 2 \
		-font RioUIFont -menu $body.profc.mb.m -text "$active ▾" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	menu $body.profc.mb.m -tearoff 0
	foreach p [dict get $pr profiles] {
		$body.profc.mb.m add radiobutton -label $p \
			-variable ::provset_profile -value $p \
			-command [list provider_profile_switch $name $p]
	}
	set ::provset_profile $active
	button $body.profc.manage -text "Manage…" -font RioUIFont \
		-command [list provider_profiles_dialog $name]
	pack $body.profc.mb -side left
	pack $body.profc.manage -side left -padx {6 0}
	grid $body.profc -row $r -column 1 -sticky we
	grid [prefs_hint $body.profn \
		"Every setting below belongs to this profile, including its API key." 420] \
		-row [incr r] -column 1 -sticky w -pady {0 2}
	return $r
}

proc provider_key_field_reveal {} {
	if {![winfo exists .provset.body.keye]} return
	.provset.body.keye configure -show [expr {$::provider_key_show ? "" : "•"}]
}

# Save and Clear: the only places a key is written. A refusal goes to the
# status line. Both then refresh the menus and repaint from the core.
proc provider_key_field_save {name} {
	if {![winfo exists .provset.body.keye]} return
	set key [string trim [.provset.body.keye get]]
	if {$key eq ""} {
		provider_settings_status "Enter an API key, or use Clear to remove the stored one." 1
		return
	}
	set resp [rio_call agent.key.set [dict create key $key name $name]]
	if {![dict get $resp ok]} {
		provider_settings_status [dict get $resp error message] 1
		return
	}
	providers_menu_fill
	provider_settings_status "Key saved."
	provider_settings_repaint $name
}

proc provider_key_field_clear {name} {
	set resp [rio_call agent.key.clear [dict create name $name]]
	if {![dict get $resp ok]} {
		provider_settings_status [dict get $resp error message] 1
		return
	}
	providers_menu_fill
	provider_settings_status "Key removed."
	provider_settings_repaint $name
}

# Rebuild the form from the core:
#
#   Profile      (if the provider keeps profiles, D131)
#   Credentials  (if it is keyed, D130)
#   its options, under their group headings
proc provider_settings_fill {} {
	set w .provset
	if {![winfo exists $w]} return
	set name $::provset_provider
	set resp [rio_call agent.options.list [dict create provider $name]]
	if {![dict get $resp ok]} {
		provider_settings_status [dict get $resp error message] 1
		return
	}
	foreach child [winfo children $w.body] { destroy $child }
	set c $::theme_colors
	set opts [dict get $resp result options]
	set r 0 ; set i 0 ; set group ""
	# The profile first: it decides what every field below shows.
	if {[provider_has_profiles $name]} {
		set r [provider_settings_profile_row $w.body $name $r]
	}
	set p [agent_provider_entry $name]
	set keyed [expr {$p ne "" && [dict get $p keyed]}]
	if {$keyed} { set r [provider_settings_credentials $w.body $name $r] }
	if {![llength $opts]} {
		grid [prefs_hint $w.body.none [expr {$keyed \
			? "This provider declares no further settings." \
			: "This provider declares no settings."}]] \
			-row [incr r] -column 0 -columnspan 2 -sticky w
	}
	foreach o $opts {
		incr i
		# A heading when the group changes. Declaration order is kept.
		set g [dict get $o group]
		if {$g ne $group} {
			set group $g
			if {$g ne ""} {
				grid [prefs_label $w.body.g$i $g] -row [incr r] -column 0 \
					-columnspan 2 -sticky w -pady {8 2}
			}
		}
		grid [prefs_label $w.body.l$i "[dict get $o label]:"] \
			-row [incr r] -column 0 -sticky w -padx {12 6}
		grid [provider_settings_control $w.body.c$i $o $name] \
			-row $r -column 1 -sticky we
		if {[dict get $o hint] ne ""} {
			grid [prefs_hint $w.body.h$i [dict get $o hint] 420] \
				-row [incr r] -column 1 -sticky w -pady {0 2}
		}
	}
	grid columnconfigure $w.body 1 -weight 1
}

# One option's control: a menu for `choice`, an entry for `text` and
# `number`, an entry with Edit… for a `file` option.
proc provider_settings_control {path o provider} {
	set c $::theme_colors
	set n [dict get $o name]
	set v [dict get $o value]
	if {[agent_option_kind $o] eq "choice"} {
		frame $path -background [dict get $c ui.bg]
		menubutton $path.mb -anchor w -relief raised -borderwidth 1 -padx 6 -pady 2 \
			-font RioUIFont -menu $path.mb.m -text "[agent_option_label $o $v] ▾" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
		menu $path.mb.m -tearoff 0
		foreach ch [dict get $o choices] {
			$path.mb.m add radiobutton -label [dict get $ch label] \
				-variable ::agent_option_value($n) -value [dict get $ch value] \
				-command [list provider_settings_write $provider $n [dict get $ch value]]
		}
		if {[dict get $o free]} {
			$path.mb.m add separator
			$path.mb.m add command -label "Other…" \
				-command [list provider_settings_other $provider $o]
		}
		pack $path.mb -side left
		# Refresh, beside the field it refills.
		if {[dict get $o refresh]} {
			button $path.rf -text "⟳ Refresh from provider" -font RioUIFont \
				-command [list agent_option_fetch $n $provider]
			pack $path.rf -side left -padx {6 0}
		}
		return $path
	}
	# A value that names a file gets an Edit… button (D131).
	if {[dict exists $o file] && [dict get $o file]} {
		frame $path -background [dict get $c ui.bg]
		set e $path.e
		entry $e -font RioUIFont -width 34 \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor] \
			-highlightthickness 1 -relief solid -borderwidth 1
		$e insert 0 $v
		ctx_bind_input $e
		bind $e <Return>   [list provider_settings_field $e $provider $n]
		bind $e <FocusOut> [list provider_settings_field $e $provider $n]
		button $path.ed -text "Edit…" -font RioUIFont \
			-command [list provider_option_edit_file $provider $n]
		pack $e -side left -fill x -expand 1
		pack $path.ed -side left -padx {6 0}
		return $path
	}
	entry $path -font RioUIFont -width 44 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-highlightthickness 1 -relief solid -borderwidth 1
	$path insert 0 $v
	ctx_bind_input $path
	bind $path <Return>   [list provider_settings_field $path $provider $n]
	bind $path <FocusOut> [list provider_settings_field $path $provider $n]
	return $path
}

# Open the file an option names, in a tab. The core resolves and creates it
# (agent.option.file).
proc provider_option_edit_file {provider name} {
	set resp [rio_call agent.option.file [dict create provider $provider name $name]]
	if {![dict get $resp ok]} {
		provider_settings_status [dict get $resp error message] 1
		return
	}
	# The provider may have just chosen a file name: repaint.
	provider_settings_repaint $provider
	do_open [dict get $resp result path]
}

# A field commits, on Return or <FocusOut>. Written only if it differs from
# what the core holds: <FocusOut> fires on every tab-through.
proc provider_settings_field {path provider name} {
	if {![winfo exists $path]} return
	set o [provider_settings_option $name]
	if {$o eq ""} return
	set v [$path get]
	if {$v eq [dict get $o value]} return
	provider_settings_write $provider $name $v
}

# One option's descriptor, fresh from the core.
proc provider_settings_option {name} {
	set resp [rio_call agent.options.list [dict create provider $::provset_provider]]
	if {![dict get $resp ok]} { return "" }
	foreach o [dict get $resp result options] {
		if {[dict get $o name] eq $name} { return $o }
	}
	return ""
}

proc provider_settings_other {provider o} {
	agent_option_other [dict get $o name] $provider $o
}

# Write one option from this window. A refusal goes to the status line. The
# form is rebuilt from the core either way.
proc provider_settings_write {provider name value} {
	set err [agent_option_write $provider $name $value]
	if {$err ne ""} {
		provider_settings_status $err 1
	} else {
		provider_settings_status "Saved."
	}
	provider_settings_repaint $provider
	if {$provider eq $::agent_provider} { agent_options_refresh }
}

# Repaint from the idle loop, always: a field's <FocusOut> handler must not
# destroy its own field, and the agent.options event arrives inside the
# channel reader, where an op call would nest.
proc provider_settings_repaint {provider} {
	if {![provider_settings_showing $provider]} return
	after idle provider_settings_fill
}

# Take the core's agent settings into the menus, at startup and after a
# reconnect. Read, never write: a daemon may already have a provider and a
# mode set, and the GUI's defaults must not reset them. A write happens only
# when the user picks something.
proc adopt_agent_status {} {
	set st [rio_result agent.status {}]
	if {$st eq ""} return   ;# error already surfaced; keep the current menu state
	set ::agent_provider    [dict get $st provider]
	set ::agent_auto_accept [dict get $st auto_accept]
	# The active profile (D131); "" from an older core.
	set ::agent_profile [expr {[dict exists $st profile] ? [dict get $st profile] : ""}]
	if {[dict exists $st mode]} { set ::agent_plan_mode [expr {[dict get $st mode] eq "plan"}] }
	providers_menu_fill    ;# refresh the cache + the provider/key menus from the core
	agent_options_refresh   ;# what this provider lets us choose, and what it chose (D106)
	agent_mode_sync         ;# and the mode control, which repaints the strip
	adopt_tls_settings      ;# the core-wide https switch sits beside it at every attach (D114)
	adopt_autosave_settings ;# and whether the core keeps recovery copies (D132)
}

# Fill Settings ▸ Agent Provider from the core's provider list, on connect
# and reconnect. The radios share ::agent_provider with Preferences.
proc providers_menu_fill {} {
	agent_providers_refresh
	if {[winfo exists .m.settings.provider]} {
		.m.settings.provider delete 0 end
		foreach p $::agent_providers {
			.m.settings.provider add radiobutton -label [provider_radio_label $p] \
				-variable ::agent_provider -value [dict get $p name] -command apply_provider
		}
	}
	extensions_menu_fill   ;# the same cache decides which extensions offer a window
}

# --- the agent's mode, as one control (D102) ---------------------------------
# The core has two flags: `mode` (build | plan, D101) and `auto_accept`
# (edits only, D83). The UI offers three states, computed from them:
#
#   Plan     mode plan
#   Review   mode build, auto_accept 0
#   Auto     mode build, auto_accept 1
#
# ::agent_mode_ui is computed, never stored. Every control writes through
# agent_mode_set and reads through agent_mode_sync.
proc agent_mode_label {m} {
	return [dict get {plan Plan review Review auto Auto} $m]
}
proc agent_mode_hint {m} {
	return [dict get {
		plan   "Plan mode: the agent reads and plans; it changes nothing until you approve a plan"
		review "Every proposed edit waits for your approval"
		auto   "Proposed edits apply as they come; commands still ask"
	} $m]
}

# Compute the control from the flags and relabel it: after a write, on an
# agent.mode event, on attach.
proc agent_mode_sync {} {
	set ::agent_mode_ui [expr {$::agent_plan_mode ? "plan" :
		($::agent_auto_accept ? "auto" : "review")}]
	if {[winfo exists .chat.hdr.mode]} {
		.chat.hdr.mode configure -text "[agent_mode_label $::agent_mode_ui] ▾"
		tooltip .chat.hdr.mode [agent_mode_hint $::agent_mode_ui]
	}
	chat_status_update
}

# Push ::agent_mode_ui to the core. Plan leaves auto-accept alone (D102). On
# a refusal the flags stay, and agent_mode_sync puts the control back.
proc agent_mode_set {} {
	set want $::agent_mode_ui
	set r [rio_call agent.mode.set [dict create mode [expr {$want eq "plan" ? "plan" : "build"}]]]
	if {![dict get $r ok]} {
		report_error [dict get $r error message] [dict get $r error code]
		agent_mode_sync
		return
	}
	set ::agent_plan_mode [expr {$want eq "plan"}]
	if {$want ne "plan"} {
		set on [expr {$want eq "auto"}]
		set r [rio_call agent.autoaccept.set [dict create on $on]]
		if {![dict get $r ok]} {
			report_error [dict get $r error message] [dict get $r error code]
			agent_mode_sync
			return
		}
		set ::agent_auto_accept $on
	}
	agent_mode_sync
}

# The allow-list editor (D84): the rules that let a command run without
# asking. A scope selector picks one of the three lists (all projects, this
# project, one provider); below it the rules, Remove, and an Add field that
# splits on whitespace.
#   ::allow_scope   the selected {scope name}
#   ::allow_rules   the rules shown, so a row maps back to its tokens
proc agent_allow_dialog {} {
	set w .agentallow
	destroy $w
	toplevel $w
	wm title $w "Allowed Commands"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set ::allow_scope [list global ""]
	set ::allow_scope_label "All projects  ▾"

	label $w.intro -anchor w -justify left -font RioUIFont -wraplength 380 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Commands whose start matches a rule below run without asking. A one-word rule (pytest) trusts every run of that program; more words (git status) trust only commands that start that way. Each scope is its own list; a command is trusted if any active scope allows it. Removing a rule makes it ask again."

	# The scope selector.
	set pr [rio_result project.get {}]
	set haveproj [expr {$pr ne "" && [dict get $pr root] ne ""}]
	agent_providers_refresh
	frame $w.scope -background [dict get $c ui.bg]
	label $w.scope.lbl -text "Scope:" -font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	menubutton $w.scope.sel -textvariable ::allow_scope_label -menu $w.scope.sel.m \
		-font RioUIFont -anchor w -relief raised -borderwidth 1 -highlightthickness 0 -padx 6 -pady 1 \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
	menu $w.scope.sel.m -tearoff 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
	$w.scope.sel.m add command -label "All projects" \
		-command [list agent_allow_set_scope $w global "" "All projects"]
	$w.scope.sel.m add command -label "This project" \
		-state [expr {$haveproj ? "normal" : "disabled"}] \
		-command [list agent_allow_set_scope $w project "" "This project"]
	set anyprov 0
	foreach p $::agent_providers {
		if {[dict get $p name] eq "echo"} continue
		set anyprov 1
		set pl [agent_provider_label [dict get $p name]]
		$w.scope.sel.m add command -label "$pl only" \
			-command [list agent_allow_set_scope $w provider [dict get $p name] "$pl only"]
	}
	if {$anyprov} { $w.scope.sel.m insert 2 separator }
	pack $w.scope.lbl -side left -padx {0 6}
	pack $w.scope.sel -side left

	frame $w.l -background [dict get $c ui.bg]
	listbox $w.l.box -height 8 -width 46 -font RioUIFont -activestyle none \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-selectbackground [dict get $c editor.selection] -selectforeground [dict get $c editor.fg] \
		-yscrollcommand [list $w.l.sb set]
	scrollbar $w.l.sb -command [list $w.l.box yview]
	pack $w.l.box -side left -fill both -expand 1
	pack $w.l.sb -side right -fill y
	frame $w.add -background [dict get $c ui.bg]
	entry $w.add.e -font RioUIFont -width 34 \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor]
	ctx_bind_input $w.add.e   ;# (D115)
	button $w.add.b -text "Add" -font RioUIFont -command [list agent_allow_add_from_entry $w]
	bind $w.add.e <Return> [list agent_allow_add_from_entry $w]
	pack $w.add.e -side left -fill x -expand 1 -padx {0 6}
	pack $w.add.b -side left
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm -text "Remove" -font RioUIFont -command [list agent_allow_remove_selected $w]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3
	pack $w.btns.rm -side right -padx 3

	grid $w.intro -row 0 -column 0 -sticky we -padx 8 -pady {8 6}
	grid $w.scope -row 1 -column 0 -sticky w  -padx 8 -pady {0 4}
	grid $w.l     -row 2 -column 0 -sticky we -padx 8 -pady 3
	grid $w.add   -row 3 -column 0 -sticky we -padx 8 -pady 3
	grid $w.btns  -row 4 -column 0 -sticky we -padx 5 -pady {6 8}
	agent_allow_refresh $w
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.add.e
}

# Switch the manager to another scope and reload its list.
proc agent_allow_set_scope {w scope name label} {
	set ::allow_scope [list $scope $name]
	set ::allow_scope_label "$label  ▾"
	agent_allow_refresh $w
}

# Repopulate the manager's listbox from the selected scope's allow-list.
proc agent_allow_refresh {w} {
	if {![winfo exists $w]} return
	lassign $::allow_scope scope name
	set res [rio_result agent.allow.list [dict create scope $scope name $name]]
	set ::allow_rules [expr {$res ne "" ? [dict get $res rules] : {}}]
	$w.l.box delete 0 end
	foreach rule $::allow_rules { $w.l.box insert end [join $rule " "] }
}

# Add the rule typed in the entry (whitespace-split into tokens) to the selected scope.
proc agent_allow_add_from_entry {w} {
	set toks [regexp -all -inline {\S+} [$w.add.e get]]
	if {![llength $toks]} return
	lassign $::allow_scope scope name
	rio_call agent.allow.add [dict create rule $toks scope $scope name $name]
	$w.add.e delete 0 end
	agent_allow_refresh $w
}

# Remove the selected rule from the selected scope, then refresh.
proc agent_allow_remove_selected {w} {
	set sel [$w.l.box curselection]
	if {![llength $sel]} return
	set rule [lindex $::allow_rules [lindex $sel 0]]
	lassign $::allow_scope scope name
	rio_call agent.allow.remove [dict create rule $rule scope $scope name $name]
	agent_allow_refresh $w
}

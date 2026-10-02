# rio-gui/prompt.tcl — the agent's prompt, layer by layer.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Preferences ▸ Agent ▸ Agent Prompts… (D70, D79, D105): every layer of the
# prompt, in the order it is composed.
#
#   base      rio's, shipped      View, or Edit your copy
#   system    yours               Edit
#   provider  yours, per provider Edit
#   project   yours, in .rio/     Edit
#   plan      rio's, shipped      View, or Edit your copy
#   composed  all of them joined  View: exactly what the provider is sent
#
# The core owns every path and text (agent.prompt.list, .get, .edit); the
# dialog never touches the filesystem. Help text is muted (D68).
# ---------------------------------------------------------------------------
# The last inventory from the core, keyed by layer name.
set ::prompt_layers {}

proc prompt_layers_refresh {} {
	set ::prompt_layers {}
	set res [rio_result agent.prompt.list {}]
	if {$res eq ""} return
	foreach l [dict get $res prompts] { dict set ::prompt_layers [dict get $l which] $l }
}

# One field of one layer, or `default` if the inventory lacks it.
proc prompt_layer_field {which field {default ""}} {
	if {![dict exists $::prompt_layers $which $field]} { return $default }
	return [dict get $::prompt_layers $which $field]
}

# A layer's state in a few words. "not in effect now": the plan layer
# outside plan mode, or the layer of a provider that is not active.
proc prompt_state_word {which} {
	if {![prompt_layer_field $which exists 0]} { return "not created yet" }
	if {[prompt_layer_field $which chars 0] == 0} { return "empty" }
	if {[prompt_layer_field $which active 0]} { return "in effect now" }
	return "not in effect now"
}

proc agent_prompts_dialog {} {
	set w .agentprompts
	destroy $w
	toplevel $w
	wm title $w "Agent Prompts"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set pr [rio_result project.get {}]
	set have_project [expr {$pr ne "" && [dict get $pr root] ne ""}]
	prompt_layers_refresh

	label $w.intro -anchor w -justify left -font RioUIFont -wraplength 460 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Every layer of what the agent is told, in the order it is composed. All of it is plain Markdown, loaded as data — never run. rio's own instructions always apply; your files add to them, and any may be left empty."

	# Base: rio's own, so a reader. With a user copy: an editor of that copy.
	set mine [expr {[prompt_layer_field base origin] eq "user"}]
	button $w.base -font RioUIFont \
		-text [expr {$mine ? "Edit your copy…" : "View rio's instructions…"}] \
		-command [expr {$mine ? [list agent_prompt_open base] : [list prompt_view base]}]
	label $w.baseh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$mine ?
			"Your copy replaces rio's — rio's own updates no longer reach it." :
			"Ships with rio: the tool contract and how the agent works — [prompt_state_word base]."}]

	button $w.sys -text "Edit system prompt…" -font RioUIFont \
		-command [list agent_prompt_open system]
	label $w.sysh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "For every project — kept with your rio settings ([prompt_state_word system])."
	button $w.proj -text "Edit project prompt…" -font RioUIFont \
		-command [list agent_prompt_open project] \
		-state [expr {$have_project ? "normal" : "disabled"}]
	label $w.projh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$have_project ?
			"For the open project — kept in its .rio/ folder ([prompt_state_word project])." :
			"Open a project folder to add one for it."}]

	# Provider (D79): a chooser of every provider but echo, which ignores
	# the prompt, and a button for the chosen one's file. Only echo: the row
	# is disabled, with a hint.
	agent_providers_refresh
	set provnames {}
	foreach p $::agent_providers {
		if {[dict get $p name] eq "echo"} continue
		lappend provnames [dict get $p name]
	}
	if {[llength $provnames]} {
		if {[lsearch -exact $provnames $::agent_provider] >= 0} {
			set ::agent_prompt_provider $::agent_provider
		} else {
			set ::agent_prompt_provider [lindex $provnames 0]
		}
		set ::agent_prompt_provider_label "[agent_provider_label $::agent_prompt_provider]  ▾"
		frame $w.prov -background [dict get $c ui.bg]
		menubutton $w.prov.sel -textvariable ::agent_prompt_provider_label \
			-menu $w.prov.sel.m -font RioUIFont -anchor w -relief raised -borderwidth 1 \
			-highlightthickness 0 -padx 6 -pady 1 \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg]
		menu $w.prov.sel.m -tearoff 0 -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c editor.selection] -activeforeground [dict get $c ui.fg]
		foreach name $provnames {
			$w.prov.sel.m add radiobutton -label [agent_provider_label $name] \
				-variable ::agent_prompt_provider -value $name \
				-command [list set ::agent_prompt_provider_label "[agent_provider_label $name]  ▾"]
		}
		button $w.prov.edit -text "Edit its prompt…" -font RioUIFont \
			-command {agent_prompt_open provider $::agent_prompt_provider}
		pack $w.prov.sel $w.prov.edit -side left -padx {0 6}
		label $w.provh -anchor w -justify left -font RioUIFont -wraplength 300 \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
			-text "Only while that provider is active — kept with your rio settings."
	} else {
		button $w.prov -text "Edit provider prompt…" -font RioUIFont -state disabled
		label $w.provh -anchor w -justify left -font RioUIFont -wraplength 300 \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
			-text "Install a provider to add provider-specific instructions."
	}

	# Plan: rio's own, like the base layer.
	set pmine [expr {[prompt_layer_field plan origin] eq "user"}]
	button $w.plan -font RioUIFont \
		-text [expr {$pmine ? "Edit your copy…" : "View plan instructions…"}] \
		-command [expr {$pmine ? [list agent_prompt_open plan] : [list prompt_view plan]}]
	label $w.planh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$pmine ?
			"Your copy replaces rio's — rio's own updates no longer reach it." :
			"Ships with rio: added only in Plan mode — [prompt_state_word plan]."}]

	# Composed: the string the provider is sent.
	button $w.full -text "Show the whole prompt…" -font RioUIFont \
		-command [list prompt_view composed]
	label $w.fullh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text "Every active layer, joined — exactly what the provider is sent."

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3

	grid $w.intro -row 0 -column 0 -columnspan 2 -sticky we -padx 8 -pady {8 6}
	grid $w.base  -row 1 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.baseh -row 1 -column 1 -sticky w -padx {0 8}
	grid $w.sys   -row 2 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.sysh  -row 2 -column 1 -sticky w -padx {0 8}
	grid $w.prov  -row 3 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.provh -row 3 -column 1 -sticky w -padx {0 8}
	grid $w.proj  -row 4 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.projh -row 4 -column 1 -sticky w -padx {0 8}
	grid $w.plan  -row 5 -column 0 -sticky w -padx {8 6} -pady 3
	grid $w.planh -row 5 -column 1 -sticky w -padx {0 8}
	grid $w.full  -row 6 -column 0 -sticky w -padx {8 6} -pady {10 3}
	grid $w.fullh -row 6 -column 1 -sticky w -padx {0 8} -pady {10 3}
	grid $w.btns  -row 7 -column 0 -columnspan 2 -sticky e -padx 5 -pady {6 8}
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.sys
}

# Show one layer in a read-only window (D105): base, plan or composed. A
# shipped layer offers "Make my own copy". Rendered as Markdown by the
# manual's renderer (D100); links are styled but do nothing.
proc prompt_view {which {name ""}} {
	set params [dict create which $which]
	if {$name ne ""} { dict set params name $name }
	set res [rio_result agent.prompt.get $params]
	if {$res eq ""} return
	set w .promptview
	destroy $w
	toplevel $w
	wm title $w [prompt_view_title $which]
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	label $w.where -anchor w -justify left -font RioUIFont -wraplength 640 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [prompt_view_where $res]
	frame $w.body -background [dict get $c ui.bg]
	text $w.body.t -wrap word -width 82 -height 28 -state disabled -cursor arrow \
		-padx 10 -pady 8 -borderwidth 0 -highlightthickness 0 \
		-yscrollcommand [list $w.body.sb set]
	ctx_bind_view $w.body.t   ;# Copy / Select All (D115)
	scrollbar $w.body.sb -command [list $w.body.t yview]
	pack $w.body.sb -side right -fill y
	pack $w.body.t -side left -fill both -expand 1

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right -padx 3
	# A copy only of a shipped layer the user has not replaced yet.
	if {$which in {base plan} && [dict get $res origin] ne "user"} {
		button $w.btns.copy -text "Make my own copy…" -font RioUIFont \
			-command [list prompt_view_copy $which]
		pack $w.btns.copy -side right -padx 3
	}

	grid $w.where -row 0 -column 0 -sticky we -padx 10 -pady {8 4}
	grid $w.body  -row 1 -column 0 -sticky nsew -padx 8
	grid $w.btns  -row 2 -column 0 -sticky e -padx 5 -pady {6 8}
	grid rowconfigure $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1

	$w.body.t configure -state normal
	$w.body.t delete 1.0 end
	help_paint $w.body.t [help_blocks [dict get $res text]]
	$w.body.t configure -state disabled
	$w.body.t yview moveto 0
	help_style $w.body.t
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.btns.close
}

# The viewer's window title.
proc prompt_view_title {which} {
	switch -- $which {
		base     { return "rio's instructions to the agent" }
		plan     { return "rio's plan-mode instructions" }
		composed { return "The whole prompt" }
	}
	return "Agent prompt"
}

# The line above the text: where it comes from. The path is the core's, so
# a remote core names the file on its own machine (D30).
proc prompt_view_where {res} {
	set path [dict get $res path]
	switch -- [dict get $res origin] {
		composed { return "Every active layer, joined in order — this is the exact text the provider is sent." }
		shipped  { return "Shipped with rio: $path — read-only here. Your own copy would override it." }
		user     { return "Your own file: $path" }
		project  { return "This project's file: $path" }
	}
	return "No file — this layer is contributing nothing."
}

# Make the user's own copy of a shipped layer and open it. The viewer and
# the list close: both would be stale.
proc prompt_view_copy {which} {
	destroy .promptview
	agent_prompt_open $which
}
# Have the core create the prompt file if needed, and open it as a tab.
#   which   system | project | provider (needs `name`) | base | plan
# For base and plan the file is the user's override, seeded with the text
# it overrides (D105).
proc agent_prompt_open {which {name ""}} {
	set params [dict create which $which]
	if {$name ne ""} { dict set params name $name }
	set resp [rio_call agent.prompt.edit $params]
	if {![dict get $resp ok]} {
		report_error "Could not open the $which prompt:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return
	}
	destroy .agentprompts
	do_open [dict get $resp result path]
}

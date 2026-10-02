# rio-gui/prompt.tcl — the agent's prompt, layer by layer.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The agent's prompt, laid out layer by layer (Preferences ▸ Agent ▸ Agent Prompts…,
# D70/D79/D105). The dialog lists EVERY layer in composition order — rio's shipped base,
# your system prompt, the active provider's, this project's, and rio's plan-mode layer —
# each with what it is, whether it is in effect right now, and a door: *Edit* for the
# three that are yours, *View* for the two that are rio's. Nothing about what the agent
# is told is hidden from the person whose project it acts on; the shipped text is one
# click away, and "Show the whole prompt…" renders exactly what the provider is sent.
#
# The CORE owns every path and every text (agent.prompt.list / .get / .edit) — a remote
# core answers from its OWN disk (D30), which is the disk that matters — so this dialog
# asks and renders, and never touches the filesystem itself. The static help is muted
# (gutter.fg); the buttons/chooser are the only interactive elements, so help never reads
# as a control (D68).
# ---------------------------------------------------------------------------
# The last inventory read from the core, keyed by layer name — so the row labels, the
# state words and the viewer's header describe what is actually in effect rather than
# what rio ships by default.
set ::prompt_layers {}

proc prompt_layers_refresh {} {
	set ::prompt_layers {}
	set res [rio_result agent.prompt.list {}]
	if {$res eq ""} return
	foreach l [dict get $res prompts] { dict set ::prompt_layers [dict get $l which] $l }
}

# One field of one layer, with a default for a core too old to answer or a layer the
# inventory did not carry.
proc prompt_layer_field {which field {default ""}} {
	if {![dict exists $::prompt_layers $which $field]} { return $default }
	return [dict get $::prompt_layers $which $field]
}

# What this layer is doing right now, in three words — the honest states are "no file
# yet", "a file that says nothing", "saying something the provider is being sent", and
# "saying something that does not apply right now" (the plan layer outside plan mode, a
# provider layer for a provider that is not live).
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

	# Layer 1 — rio's own. Shipped, so the door is a reader, not an editor; once the user
	# has made their own copy the door changes to that copy, because that is now the text
	# in effect.
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

	# The per-provider row (D79): instructions for ONE provider, applied only while
	# that provider is active. The chooser lists every provider except echo (which
	# ignores the system prompt entirely); the button opens that provider's
	# providers/<name>.md via agent.prompt.edit. When only echo is present the row is
	# disabled with a hint — provider prompts need a provider to attach to.
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

	# Layer 5 — rio's plan-mode instructions. Same offer as the base layer, and the same
	# reason for it: it is rio's machinery, so it is readable, and replaceable by a copy.
	set pmine [expr {[prompt_layer_field plan origin] eq "user"}]
	button $w.plan -font RioUIFont \
		-text [expr {$pmine ? "Edit your copy…" : "View plan instructions…"}] \
		-command [expr {$pmine ? [list agent_prompt_open plan] : [list prompt_view plan]}]
	label $w.planh -anchor w -justify left -font RioUIFont -wraplength 300 \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg] \
		-text [expr {$pmine ?
			"Your copy replaces rio's — rio's own updates no longer reach it." :
			"Ships with rio: added only in Plan mode — [prompt_state_word plan]."}]

	# And the whole thing, joined: the one view that cannot mislead, because it is
	# literally the string the provider is handed.
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

# Read one prompt layer, rendered, in a window of its own (D105) — rio's shipped base or
# plan-mode instructions, or `composed`, the finished string the provider is sent. It is a
# READER: the text belongs to rio (or, for `composed`, to no single file), so there is
# nothing here to save. What there is, for a shipped layer, is *Make my own copy*, which
# hands the same text back as an editable override in the user's own agent dir.
#
# Rendered with the manual's renderer (help_blocks → help_paint, D100), like the plan view
# (D101) — these ARE Markdown documents, and reading them as a rendered page is the whole
# point of showing them at all. Links are styled but inert here, as in the plan view: the
# renderer's click binding follows a manual topic, which is not what a link in a prompt
# means.
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
	# The copy is offered only where it means something: a shipped layer the user has not
	# already replaced. `composed` has no file to copy, and an override is already theirs.
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

# The viewer's window title — what you are reading, not which layer number it is.
proc prompt_view_title {which} {
	switch -- $which {
		base     { return "rio's instructions to the agent" }
		plan     { return "rio's plan-mode instructions" }
		composed { return "The whole prompt" }
	}
	return "Agent prompt"
}

# The line above the text: where it comes from, in the words the inventory uses. The path
# is the core's, so a remote core names the file on the machine the agent actually runs on
# (D30) — which is the answer to "where do I change this?".
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

# Turn a shipped layer into the user's own copy: the core writes the override, seeded with
# the text that was in effect (agent.prompt.edit, D105), and it opens as an ordinary tab.
# The viewer and the list both close — what is in effect has just changed, and a list that
# still said "ships with rio" would be describing the past.
proc prompt_view_copy {which} {
	destroy .promptview
	agent_prompt_open $which
}
# Ask the core to resolve+create the prompt file, then open it as a normal tab. `which`
# is system | project | provider — or base | plan, where the file created is the user's
# OVERRIDE of a shipped layer, seeded by the core with a copy of the text it overrides
# (D105), so "make my own copy" opens the text the user just read rather than a blank
# page. A provider prompt also needs `name` (the chosen provider). The core raises
# bad_request for `project` with no open project or a bad provider name — but the relevant
# control is disabled/validated here, so those are safety nets, surfaced through the usual
# error path.
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

# rio-gui/layout.tcl — the panel registry, the dock layout, the editor-group accessors.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The tool-panel registry (D35). The four panes (files, git, chat, search)
# are declared as data: {title site body refresh}.
#   site     the preferred dock site: left | right | bottom
#   body     the body widget's path
#   refresh  the proc that repaints it; "" for the chat, which is event-driven
# Where a panel is now is in ::layout, below.
# ---------------------------------------------------------------------------
namespace eval rio::panel {
	variable order {}       ;# registered ids, in registration order
	variable meta           ;# id -> {title site body refresh}
	array set meta {}
}
# Declare a panel. Registering an id twice is a no-op.
proc rio::panel::register {id spec} {
	variable order ; variable meta
	if {[info exists meta($id)]} return
	lappend order $id
	set meta($id) [dict merge {title {} site {} body {} refresh {}} $spec]
}
proc rio::panel::ids {}         { variable order ; return $order }
proc rio::panel::exists {id}    { variable meta ; info exists meta($id) }
proc rio::panel::get {id}       { variable meta ; return $meta($id) }
proc rio::panel::field {id key} { variable meta ; dict get $meta($id) $key }
# Repaint a panel through its refresh hook, if it has one.
proc rio::panel::refresh {id} {
	variable meta
	if {![info exists meta($id)]} return
	set hook [dict get $meta($id) refresh]
	if {$hook ne ""} { uplevel #0 $hook }
}

# ---------------------------------------------------------------------------
# The dock layout (D35). ::layout says where every panel is; apply_layout
# packs the window from it.
#
#   ┌──────┬───────────────┬───────┐     ::layout = {sites {
#   │ left │    editor     │ right │        left   {panels … hidden … active … visible … size …}
#   │      │               │       │        right  {…}
#   ├──────┴───────────────┴───────┤        bottom {…}}}
#   │            bottom            │
#   └──────────────────────────────┘
#
#   panels   the site's panels, in tab order
#   hidden   those of them without a tab
#   active   the panel in front
#   visible  derived: is any panel shown?
#   size     width (left, right) or height (bottom)
#
# ::dock_side, ::dock_pane, ::chat_shown and ::search_shown are copies that
# apply_layout keeps current, for the View menu's -variable bindings.
# ---------------------------------------------------------------------------
namespace eval rio::layout {}

# The first-run layout: only Files is shown, on the left. Git, the Agent and
# Search have no tab yet.
proc rio::layout::default {} {
	return [dict create sites [dict create \
		left   [dict create panels {files git} hidden {git}    active files  visible 1 size 220] \
		right  [dict create panels {chat}      hidden {chat}   active chat   visible 0 size 340] \
		bottom [dict create panels {search}    hidden {search} active search visible 0 size 160]]]
}
proc rio::layout::get {site key}   { dict get $::layout sites $site $key }
proc rio::layout::put {site key v} { dict set ::layout sites $site $key $v }
# Which site holds panel `id` (its first membership), or "" if none.
proc rio::layout::site_of {id} {
	dict for {s d} [dict get $::layout sites] {
		if {$id in [dict get $d panels]} { return $s }
	}
	return ""
}
# The side (left|right) the files/git dock sits on.
proc rio::layout::dockside {} { return [site_of files] }
# A copy of `list` with any of `ids` removed (order preserved).
proc rio::layout::_without {list ids} {
	set out {} ; foreach x $list { if {$x ni $ids} { lappend out $x } }
	return $out
}
# A site's `hidden` list (panels present but with NO tab), defaulting to empty.
proc rio::layout::hidden_of {site} {
	if {[dict exists $::layout sites $site hidden]} { return [dict get $::layout sites $site hidden] }
	return {}
}
# The panels currently SHOWN in `site` (a tab each) — membership minus hidden, order kept.
proc rio::layout::shown_panels {site} {
	return [_without [get $site panels] [hidden_of $site]]
}
# Give panel `id` a tab in `site` (remove it from hidden) / take its tab away (add it).
proc rio::layout::unhide {site id} { put $site hidden [_without [hidden_of $site] [list $id]] }
proc rio::layout::hide   {site id} {
	set h [hidden_of $site]
	if {$id ni $h} { lappend h $id }
	put $site hidden $h
}
# Has panel `id` a tab? In front or not.
proc rio::layout::shown {id} {
	set s [site_of $id]
	if {$s eq ""} { return 0 }
	return [expr {$id ni [hidden_of $s]}]
}

# A layout from the older flat prefs keys:
#   dock_side    which side holds files and git
#   dock_pane    that site's active panel
#   chat_shown   has the Agent a tab?
# Files and git both get a tab, as they had. Search stays hidden.
proc rio::layout::migrate {prefs} {
	set L [default]
	set side [expr {[dict exists $prefs dock_side] && [dict get $prefs dock_side] eq "right" ? "right" : "left"}]
	set pane [expr {[dict exists $prefs dock_pane] && [dict get $prefs dock_pane] eq "git" ? "git" : "files"}]
	set chat [expr {[dict exists $prefs chat_shown] && ![dict get $prefs chat_shown] ? 0 : 1}]
	dict set L sites left   hidden {}          ;# both files and git shown (old behaviour)
	dict set L sites bottom hidden {search}    ;# Search on-demand
	if {$side eq "right"} {
		dict set L sites left  panels {}
		dict set L sites left  active ""
		dict set L sites right panels {files git chat}
	}
	dict set L sites $side active $pane                       ;# the dock's files|git choice
	dict set L sites right hidden [expr {$chat ? {} : {chat}}] ;# Agent tab per chat_shown
	return $L
}

# Repair a layout:
# - missing keys come from the default; unknown sites are dropped;
# - every registered panel is in exactly one site (an unclaimed one goes to
#   its preferred site);
# - `hidden` holds only members; a layout without `hidden` gets it from
#   `visible` (0: all hidden);
# - `visible` is derived; `active` is a shown panel.
proc rio::layout::normalize {L} {
	set out [default]
	set had_hidden {}   ;# sites whose source dict supplied an explicit `hidden`
	if {[dict exists $L sites]} {
		dict for {s d} [dict get $L sites] {
			if {$s ni {left right bottom}} continue
			foreach k {panels active visible size hidden} {
				if {[dict exists $d $k]} { dict set out sites $s $k [dict get $d $k] }
			}
			if {[dict exists $d hidden]} { lappend had_hidden $s }
		}
	}
	# Each panel in exactly one site; the first claim wins.
	set seen {}
	dict for {s d} [dict get $out sites] {
		set keep {}
		foreach p [dict get $d panels] {
			if {[rio::panel::exists $p] && $p ni $seen} { lappend keep $p ; lappend seen $p }
		}
		dict set out sites $s panels $keep
	}
	foreach p [rio::panel::ids] {
		if {$p ni $seen} {
			set pref [rio::panel::field $p site]
			dict set out sites $pref panels [concat [dict get $out sites $pref panels] [list $p]]
			lappend seen $p
		}
	}
	dict for {s d} [dict get $out sites] {
		set ps [dict get $out sites $s panels]
		# No `hidden` in the source: visible 0 means all hidden.
		if {$s ni $had_hidden} {
			set vis [expr {[dict exists $d visible] ? [dict get $d visible] : 1}]
			dict set out sites $s hidden [expr {$vis ? {} : $ps}]
		}
		# Clamp hidden to current members (read from $out, not the global ::layout).
		set cur_hidden [expr {[dict exists $out sites $s hidden] ? [dict get $out sites $s hidden] : {}}]
		set hid {} ; foreach p $cur_hidden { if {$p in $ps} { lappend hid $p } }
		dict set out sites $s hidden $hid
		# Derive visible from what's shown; keep active a shown pane.
		set show [_without $ps $hid]
		dict set out sites $s visible [expr {[llength $show] ? 1 : 0}]
		if {[dict get $out sites $s active] ni $show} {
			dict set out sites $s active [expr {[llength $show] ? [lindex $show 0] : ""}]
		}
	}
	return $out
}
# normalize, plus at boot: Search starts hidden if it is alone in the bottom
# site. With other panels docked there, the saved state stands.
proc rio::layout::boot {L} {
	set out [normalize $L]
	if {[dict get $out sites bottom panels] eq "search"} {
		dict set out sites bottom hidden {search}
	}
	return [normalize $out]
}
# ::layout as JSON for prefs.json:
#   {"sites":{"left":{"panels":[…],"hidden":[…],"active":"…","visible":true,"size":220},…}}
proc rio::layout::json {} {
	set sites {}
	dict for {s d} [dict get $::layout sites] {
		set obj [format {{"panels":%s,"hidden":%s,"active":%s,"visible":%s,"size":%d}} \
			[rio::wire::strarr [dict get $d panels]] \
			[rio::wire::strarr [hidden_of $s]] \
			[rio::wire::str [dict get $d active]] \
			[expr {[dict get $d visible] ? "true" : "false"}] \
			[expr {int([dict get $d size])}]]
		lappend sites "[rio::wire::str $s]:$obj"
	}
	return "{\"sites\":{[join $sites ,]}}"
}
set ::layout [rio::layout::default]   ;# real value is set by prefs_load (migrate/adopt)

proc bufget {id key} { dict get $::buffers $id $key }
proc bufset {id key val} { dict set ::buffers $id $key $val }

# ---------------------------------------------------------------------------
# Editor-group accessors (D33). A group is a dict in ::grp.
# ---------------------------------------------------------------------------
proc fg {}         { return $::focus }                 ;# the focused group id
proc gget {g k}    { dict get $::grp $g $k }
proc gset {g k v}  { dict set ::grp $g $k $v }
proc gw {g}        { dict get $::grp $g w }            ;# real widget command (bypasses the proxy)
proc gcur {g}      { dict get $::grp $g cur }          ;# active buffer id in group g
proc gorder {g}    { dict get $::grp $g order }        ;# tab order in group g
proc fgw {}        { gw $::focus }                     ;# the focused group's real widget

# Which group currently shows buffer `id`, or "" if none (v1: at most one group).
proc group_of {id} {
	foreach g $::groups { if {[lsearch -exact [gorder $g] $id] >= 0} { return $g } }
	return ""
}

# A new group's state. make_editor_group fills in w, path, frame and tabs.
proc new_group_state {} {
	return [dict create w "" path "" frame "" tabs "" cur "" order {} taboff 0 \
		hl_scan "" hl_lang "" hl_pending 0 hl_enter {} \
		hl_dirty 0 hl_lastchanged 0 hl_scanned 0 \
		hl_lo 0 hl_hi 0 hl_vpending 0]
}

# ---------------------------------------------------------------------------
# The dock: which panel shows, and on which edge.
# ---------------------------------------------------------------------------
# Reveal a panel where it is: give it a tab, bring it to the front, refresh
# (Ctrl+E, Ctrl+G). So no panel is ever unreachable.
proc panel_reveal {id} {
	set s [rio::layout::site_of $id]
	if {$s eq ""} return
	rio::layout::unhide $s $id
	rio::layout::put $s active $id
	set ::layout [rio::layout::normalize $::layout]   ;# recompute derived visible
	apply_layout
	rio::panel::refresh $id
}
proc show_pane {which} { panel_reveal $which }

# The View menu's toggle. Hiding takes the panel's tab away; the site's last
# tab gone, the site collapses. Showing gives the tab back, in front.
proc panel_toggle {id} {
	set s [rio::layout::site_of $id]
	if {$s eq ""} return
	if {[rio::layout::shown $id]} {
		rio::layout::hide $s $id
	} else {
		rio::layout::unhide $s $id
		rio::layout::put $s active $id
	}
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	rio::panel::refresh $id
}

# Draw a site's tab strip: one label per shown panel, the active one
# highlighted. Rebuilt on every layout pass.
proc render_tabs {site} {
	set f .site$site.tabs
	foreach w [winfo children $f] { destroy $w }
	set c $::theme_colors
	set active [rio::layout::get $site active]
	foreach id [rio::layout::shown_panels $site] {
		set t $f.$id
		label $t -text [rio::panel::field $id title] -font RioUIFont -padx 8 -pady 1 \
			-foreground [dict get $c tab.fg] \
			-background [expr {$id eq $active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
		pack $t -side left -padx 1 -pady 1
		# Press, motion, release: a click or a drag. Right-click: Move to.
		bind $t <ButtonPress-1>   [list tab_press $site $id %X %Y]
		bind $t <B1-Motion>       [list tab_motion %X %Y]
		bind $t <ButtonRelease-1> [list tab_release $site $id %X %Y]
		bind $t <<ContextMenu>>   [list site_tab_menu $site $id %X %Y]
	}
}

# A tab click: bring panel `id` to the front of its site. Only this site is
# repainted; apply_layout would re-pack the whole window and flicker.
proc site_tab_click {site id} {
	set prev [rio::layout::get $site active]
	if {$prev eq $id} { rio::panel::refresh $id ; return }
	rio::layout::put $site active $id
	if {$prev ne ""} { catch {pack forget [rio::panel::field $prev body]} }
	render_tabs $site
	render_site_body $site
	if {$site eq [rio::layout::dockside]} {
		set da [rio::layout::get $site active]
		set ::dock_pane [expr {$da in {files git} ? $da : "files"}]
	}
	prefs_save
	rio::panel::refresh $id
}

# Pack a site's active panel body into its .body area. A body is a child of
# the toplevel, packed with -in, so it must be raised above the site.
proc render_site_body {site} {
	set active [rio::layout::get $site active]
	if {$active eq ""} return
	set body [rio::panel::field $active body]
	pack $body -in .site$site.body -fill both -expand 1
	raise $body .site$site.body
}

# Pack the window from ::layout (D35). Each visible site shows its tab strip
# and its active body. The bottom site is packed first, so it spans the full
# width. The centre is the editor groups, or the compare or plan view. Also
# updates the ::dock_*, ::chat_shown, ::search_shown and ::shown_* copies.
proc apply_layout {} {
	set ds [rio::layout::dockside]                 ;# left|right — the files/git side
	set da [rio::layout::get $ds active]
	set ::dock_side  $ds
	set ::dock_pane  [expr {$da in {files git} ? $da : "files"}]
	set ::chat_shown [rio::layout::get [rio::layout::site_of chat] visible]
	set ::search_shown [rio::layout::get bottom visible]
	# Per-pane shown mirrors for the View-menu toggle checkmarks (has a tab / not hidden).
	foreach _p {files git chat search} { set ::shown_$_p [rio::layout::shown $_p] }

	catch {pack forget .siteleft .siteright .sitebottom .sash .csash .bsash .groups .cmp .plan}
	foreach id [rio::panel::ids] { catch {pack forget [rio::panel::field $id body]} }

	set showL [expr {[rio::layout::get left   visible] && [llength [rio::layout::get left   panels]]}]
	set showR [expr {[rio::layout::get right  visible] && [llength [rio::layout::get right  panels]]}]
	set showB [expr {[rio::layout::get bottom visible] && [llength [rio::layout::get bottom panels]]}]

	if {$showB} {
		render_tabs bottom ; render_site_body bottom
		pack .sitebottom -side bottom -fill x
		pack .bsash -side bottom -fill x          ;# height grip on the dock's top edge
		.sitebottom configure -height [rio::layout::get bottom size]
	}
	if {$showL} {
		render_tabs left ; render_site_body left
		pack .siteleft -side left -fill y ; pack .sash -side left -fill y
		.siteleft configure -width [rio::layout::get left size]
	}
	if {$showR} {
		render_tabs right ; render_site_body right
		pack .siteright -side right -fill y ; pack .csash -side right -fill y
		.siteright configure -width [rio::layout::get right size]
	}
	if {$::plan_shown} {
		pack .plan -side left -fill both -expand 1
	} elseif {$::compare_shown} {
		pack .cmp -side left -fill both -expand 1
	} else {
		pack .groups -side left -fill both -expand 1
	}
	prefs_save
}

# Move files and git to `side` (View ▸ Dock Left / Right), with their active
# panel, their size and their tabs.
proc dock_set_side {side} {
	if {$side ni {left right}} return
	set cur  [rio::layout::dockside]
	if {$cur eq $side} return
	set pane [rio::layout::get $cur active]
	set size [rio::layout::get $cur size]
	# Carry each of files/git's tab-presence (hidden) state across the move.
	set curhid [rio::layout::hidden_of $cur]
	set moved_hidden {} ; foreach p {files git} { if {$p in $curhid} { lappend moved_hidden $p } }
	dict set ::layout sites $cur  panels [rio::layout::_without [rio::layout::get $cur panels] {files git}]
	dict set ::layout sites $cur  hidden [rio::layout::_without $curhid {files git}]
	dict set ::layout sites $side panels [concat {files git} [rio::layout::_without [rio::layout::get $side panels] {files git}]]
	dict set ::layout sites $side hidden [concat [rio::layout::_without [rio::layout::hidden_of $side] {files git}] $moved_hidden]
	dict set ::layout sites $side active $pane
	dict set ::layout sites $side size $size
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
}

# Move one panel to another site (Move to, or a tab drag). It arrives with a
# tab, in front.
proc panel_move {id target} {
	if {$target ni {left right bottom}} return
	set from [rio::layout::site_of $id]
	if {$from eq $target || $from eq ""} return
	dict set ::layout sites $from   panels [rio::layout::_without [rio::layout::get $from panels] [list $id]]
	dict set ::layout sites $from   hidden [rio::layout::_without [rio::layout::hidden_of $from] [list $id]]
	dict set ::layout sites $target panels [concat [rio::layout::get $target panels] [list $id]]
	rio::layout::unhide $target $id            ;# lands with a tab
	dict set ::layout sites $target active $id
	set ::layout [rio::layout::normalize $::layout]
	apply_layout
	rio::panel::refresh $id
}

# A tab's context menu: Move to Left, Right or Bottom; its own site is greyed.
proc site_tab_menu {site id X Y} {
	catch {destroy .sitetabmenu}
	menu .sitetabmenu -tearoff 0
	menu .sitetabmenu.to -tearoff 0
	.sitetabmenu add cascade -label "Move to" -menu .sitetabmenu.to
	foreach {t label} {left Left right Right bottom Bottom} {
		.sitetabmenu.to add command -label $label \
			-state [expr {$t eq $site ? "disabled" : "normal"}] \
			-command [list panel_move $id $t]
	}
	tk_popup .sitetabmenu $X $Y
}

# The dock site under screen point X,Y, or "": a tab drag's drop target. The
# pointer may be over the site's own widgets or over a panel body, which is
# not a child of the site.
proc site_under_pointer {X Y} {
	set w [winfo containing $X $Y]
	if {$w eq ""} return ""
	foreach s {left right bottom} {
		if {$w eq ".site$s" || [string match ".site$s.*" $w]} { return $s }
	}
	foreach id [rio::panel::ids] {
		set body [rio::panel::field $id body]
		if {$w eq $body || [string match "$body.*" $w]} { return [rio::layout::site_of $id] }
	}
	return ""
}

# Tint the drop target's tab strip with the accent; "" clears it.
proc tabdrag_highlight {site} {
	foreach s {left right bottom} {
		if {![winfo exists .site$s.tabs]} continue
		.site$s.tabs configure -background \
			[dict get $::theme_colors [expr {$s eq $site ? "accent" : "ui.bg"}]]
	}
}

# Tab drag (D35): press records the tab; a move of 6 px or more starts a drag
# and lights the site under the pointer; release moves the panel there. A
# release without a drag is a click.
proc tab_press {site id X Y} {
	set ::tabdrag [dict create id $id from $site x0 $X y0 $Y active 0 over ""]
}
proc tab_motion {X Y} {
	if {![info exists ::tabdrag]} return
	if {![dict get $::tabdrag active]} {
		if {abs($X - [dict get $::tabdrag x0]) < 6 && abs($Y - [dict get $::tabdrag y0]) < 6} return
		dict set ::tabdrag active 1
	}
	set over [site_under_pointer $X $Y]
	if {$over ne [dict get $::tabdrag over]} {
		dict set ::tabdrag over $over
		set from [dict get $::tabdrag from]
		tabdrag_highlight [expr {($over ne "" && $over ne $from) ? $over : ""}]
	}
}
proc tab_release {site id X Y} {
	if {![info exists ::tabdrag]} { site_tab_click $site $id ; return }
	set dragging [dict get $::tabdrag active]
	set from     [dict get $::tabdrag from]
	unset ::tabdrag
	tabdrag_highlight ""
	if {!$dragging} { site_tab_click $site $id ; return }   ;# never crossed the threshold — a click
	set over [site_under_pointer $X $Y]
	if {$over ne "" && $over ne $from} { panel_move $id $over }
}

# Put the editor groups side by side in the .groups panedwindow, after a
# split or an unsplit.
proc relayout_groups {} {
	foreach p [.groups panes] { .groups forget $p }
	foreach g $::groups {
		.groups add [gget $g frame] -stretch always -minsize 120
	}
}

# Centre the sash, so a new split opens 50/50. Only when a split is created:
# a sash the user dragged stays. After idle, when the width is known.
proc even_split {} {
	if {[llength [.groups panes]] != 2} return
	set w [winfo width .groups]
	if {$w <= 1} return                       ;# not mapped yet (e.g. headless) — skip
	.groups sash place 0 [expr {$w / 2}] 0
}

# Drag the sash: resize the left site. The width is the pointer's distance
# from the toplevel's left edge, which does not move. Clamped, so neither
# side collapses.
proc sash_drag {} {
	set total [winfo width .]
	set min 120
	set max [expr {$total - 200}]
	set w [expr {[winfo pointerx .] - [winfo rootx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteleft configure -width $w
}

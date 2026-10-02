# rio-gui/layout.tcl — the panel registry, the dock layout, the editor-group accessors.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Tool-panel registry (D35, incremental path step (a)). The four tool
# panes rio ships — files, git, the agent chat, and the Search results strip — are
# *declared as data* here rather than hand-wired at their call sites: same idiom as
# the core's highlighter/mode/rich-list registries. Each panel is {title, site,
# body, refresh}: `site` is its preferred dock site (left|right|bottom — the eventual
# D35 sites; the actual, user-movable placement becomes the persisted `layout` object
# in step (b), not modelled here), `body` its body-widget path, `refresh` the proc
# that repaints it ("" for the event-driven chat). The registry is the queryable
# state seed (decision #6): smoke asserts a panel's identity/site without a mapped
# window. Placement is untouched at this step — this only names the four panes and
# routes their refresh through one dispatch; the sites/tab-strips/drag come in
# steps (b)/(c). Files and git are two distinct panels that share one side site.
# ---------------------------------------------------------------------------
namespace eval rio::panel {
	variable order {}       ;# registered ids, in registration order
	variable meta           ;# id -> {title site body refresh}
	array set meta {}
}
# Declare a panel. Idempotent (re-registering the same id is a no-op) so a reloaded
# GUI in one interp doesn't duplicate. `spec` fills in over the defaults.
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
# Repaint one panel through its declared refresh hook (a no-op when it has none, or
# when the id is unknown). The single dispatch the pane call sites route through.
proc rio::panel::refresh {id} {
	variable meta
	if {![info exists meta($id)]} return
	set hook [dict get $meta($id) refresh]
	if {$hook ne ""} { uplevel #0 $hook }
}

# ---------------------------------------------------------------------------
# The dock layout (D35, incremental path step (b)). One persisted
# `layout` object (::layout) is the single source of truth for all non-document
# placement: three sites (left|right|bottom), each with an ordered `panels` list,
# an `active` panel, `visible`, and `size` (width for the side sites, height for
# the bottom). apply_layout DERIVES the pack from this state (decision #6 — state
# is authoritative, pack is derived); the old ::dock_side / ::dock_pane /
# ::chat_shown / ::search_shown globals live on only as read *mirrors* that
# apply_layout keeps in sync, because the View-menu radio/checkbuttons bind them
# as -variable and several call sites (on_fs_changed, refresh_dock) read them.
# v1 invariants: files+git move together and are the only pair selected via a
# site's `active`; chat is the right site's tenant; the Search strip is the
# bottom site's, booting hidden (on-demand). Sizes are newly persisted.
# ---------------------------------------------------------------------------
namespace eval rio::layout {}

# The seed layout — also the normalize/migrate base. Side widths (220 dock,
# 340 chat), bottom height (160 search).
# The first-run layout a brand-new user sees (no prefs yet): only the Files tab is
# shown, on the left; Git lives there too but starts HIDDEN (no tab), and the Agent
# (right) and Search (bottom) start hidden as well — so a fresh rio is just the editor
# and the file tree. `hidden` lists the panels with no tab; `visible` is derived from
# it (a site shows iff it has a non-hidden pane). Everything past this is the user's
# own choice and persists (prefs.json).
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
# Is panel `id` shown — i.e. does it have a tab (is it loaded), regardless of which
# tab is foreground? "Hide" a pane means no tab at all, so the View-menu checkmark
# tracks tab presence, not the active/foreground selection.
proc rio::layout::shown {id} {
	set s [site_of $id]
	if {$s eq ""} { return 0 }
	return [expr {$id ni [hidden_of $s]}]
}

# Build a layout from the pre-step-(b) flat keys, over the default: dock_pane ->
# the dock site's active; chat_shown -> whether the Agent has a tab; dock_side ->
# which side holds files/git. dock_side=right unifies the dock into the right site
# alongside chat (decision 1a). The pre-layout model showed a tab for EVERY dock
# member (git was a background tab, not hidden), so an upgraded dock shows both files
# and git — distinct from the new first-run default, which hides git. Search stays
# on-demand (hidden). Sizes take defaults (were ephemeral before).
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

# Repair a persisted or migrated layout into a well-formed one: fill missing keys
# from the default, drop unknown sites, ensure each registered panel appears in
# exactly one site (unclaimed panels land in their registry-preferred site), clamp
# `hidden` to real members, DERIVE `visible` from what's shown (a site is on-screen
# iff it has a non-hidden pane), and keep `active` a SHOWN member. Old persisted
# layouts predate `hidden`; for a site without it we recover it from the stored
# `visible` (a collapsed dock — visible 0 — becomes all-hidden, else all-shown).
# Used at runtime after a relocation; the boot-only "Search starts hidden" is in boot.
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
	# Membership: each registered panel in exactly one site (first claim wins);
	# unclaimed panels return to their registry-preferred site.
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
		# Recover `hidden` for an old layout that lacks it: visible 0 -> the dock was
		# collapsed (all panels hidden), visible 1/absent -> all shown.
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
# normalize + the boot-time policy: the Search strip is an on-demand surface, so the
# bottom site starts hidden *when Search is its only tenant*. But once the user has
# docked other panels there (e.g. dragged Git down), honour the persisted visibility
# — otherwise those panels would be stranded in a site nothing reopens. Used only at
# prefs_load; runtime relocations use normalize so a panel moved to the bottom shows.
proc rio::layout::boot {L} {
	set out [normalize $L]
	if {[dict get $out sites bottom panels] eq "search"} {
		dict set out sites bottom hidden {search}
	}
	return [normalize $out]
}
# Encode ::layout as a JSON object fragment for prefs.json. `panels`/`hidden` are
# string arrays, `visible` a JSON boolean (derived, kept for compat), `size` a bare
# integer; the shape mirrors what normalize accepts on read (json2dict yields nested
# dicts/lists). `hidden` is the authoritative per-pane tab-presence state.
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
# Editor-group accessors (D33). A group is a dict in ::grp; these keep the
# editor procs terse — most take a group id defaulting to the focused one, resolve
# its widget/cache through here, and never touch ::grp directly.
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

# A fresh group-state dict: no buffer yet, an empty tab order, a clean highlight cache.
# `w`/`path`/`frame`/`tabs` are filled in by make_editor_group once the widgets exist.
proc new_group_state {} {
	return [dict create w "" path "" frame "" tabs "" cur "" order {} taboff 0 \
		hl_scan "" hl_lang "" hl_pending 0 hl_enter {} \
		hl_dirty 0 hl_lastchanged 0 hl_scanned 0 \
		hl_lo 0 hl_hi 0 hl_vpending 0]
}

# ---------------------------------------------------------------------------
# The dock: which pane shows, and which edge it sits on. Both are runtime choices
# driven from the View menu; apply_layout and show_pane are the two seams.
# ---------------------------------------------------------------------------
# Reveal a panel wherever it currently lives: give it a tab (unhide) in its site and
# make it the active/foreground one, then refresh. The robust "show me pane X" the
# reveal keys (Ctrl+E/G) use — it works even when the panel was hidden or in another
# site, so a panel can always be recovered (no pane ever becomes unreachable).
proc panel_reveal {id} {
	set s [rio::layout::site_of $id]
	if {$s eq ""} return
	rio::layout::unhide $s $id
	rio::layout::put $s active $id
	set ::layout [rio::layout::normalize $::layout]   ;# recompute derived visible
	apply_layout
	rio::panel::refresh $id
}
# Back-compat: "show the files/git pane" (Ctrl+E/G) is a reveal (idempotent "go to").
proc show_pane {which} { panel_reveal $which }

# Show/hide a pane — the View-menu checkbuttons' toggle. "Hide" means NO TAB at all
# (not merely backgrounded): a shown pane loses its tab (added to the site's hidden
# list); if it was the foreground tab, another shown pane takes over, and if it was
# the site's last shown pane the whole dock collapses. A hidden pane is revealed (tab
# back + foreground). normalize re-derives the site's visibility and active; apply_layout
# resyncs the ::shown_* mirrors so the checkmarks track tab presence.
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

# Draw site `site`'s host tab strip: one label per docked panel (its registry
# title), the active one highlighted like a selected tab. Rebuilt from scratch each
# layout pass (cheap — a handful of labels) so it always matches ::layout. Clicking
# a tab activates that panel. This replaces the old bespoke Files/Git selector.
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
		# Press/motion/release drive click-vs-drag (D35 c3); right-click is Move to (c2).
		bind $t <ButtonPress-1>   [list tab_press $site $id %X %Y]
		bind $t <B1-Motion>       [list tab_motion %X %Y]
		bind $t <ButtonRelease-1> [list tab_release $site $id %X %Y]
		bind $t <<ContextMenu>>   [list site_tab_menu $site $id %X %Y]
	}
}

# Activate panel `id` in site `site` (a tab click). Only which body shows in THIS
# site changes — sizes, edges and the other sites are untouched — so we swap in
# place instead of calling apply_layout, which forgets and re-packs every site,
# sash and the center editor area and makes the whole window flicker (D35 polish).
# The outgoing body is forgotten, this site's tab strip + body re-rendered, the
# dockside mirror kept correct (View menu radios read ::dock_pane), and prefs saved.
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

# Pack site `site`'s active panel body into its .body area. Bodies are toplevel
# children moved between sites via -in; a slave packed into a non-parent master must
# be raised above it or it is obscured.
proc render_site_body {site} {
	set active [rio::layout::get $site active]
	if {$active eq ""} return
	set body [rio::panel::field $active body]
	pack $body -in .site$site.body -fill both -expand 1
	raise $body .site$site.body
}

# Derive the whole non-document layout from ::layout (D35 step b/c) — the single
# choke point that replaces the old place_dock/show_pane/search packing. Each site
# (when visible and non-empty) renders its tab strip + active body and claims its
# edge; the center is the editor groups (or the compare view in their place, D28).
# The bottom site is packed first so it spans the full width and the side docks stop
# above it (the old Search-strip behaviour). The legacy ::dock_* / ::chat_shown /
# ::search_shown globals are refreshed from the sites so menus and read-only call
# sites stay correct (::dock_pane is pinned to files|git — the dock's selection —
# even when its site's active tab is another panel like chat).
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

# Move the files/git dock to `side` (View ▸ Dock Left/Right). Carries the active
# files|git choice and the dock's size; the other side keeps its remaining tenants
# (e.g. chat). normalize repairs membership/actives; moving there implies showing.
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

# Relocate one panel to another site (D35 c2 — the right-click "Move to" gesture).
# The panel lands with a tab (shown) and becomes its new site's foreground pane; it
# leaves its old site's membership AND hidden list. normalize repairs the site it
# left (active/emptiness) and derives visibility. Refresh so it paints fresh.
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

# Pop the tab's context menu: move this panel to a site it isn't already in. Built
# fresh each time (like the nav/git menus), so the current site is greyed out.
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

# Which dock site (left|right|bottom) the pointer at screen X,Y is over, or "" if
# none — used as the drop target while dragging a tab (D35 c3). The pointer may be
# over a site's chrome (.site$s.*) OR over a panel body, which is a toplevel child
# packed -in the site (path .pfiles/.chat/.results, not under .site$s), so map that
# body back to its panel and thence to the site it currently sits in.
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

# Tint each site's tab strip: the drop-target `site` gets the accent, the rest go
# back to their normal bar colour. Called during a drag and cleared on drop.
proc tabdrag_highlight {site} {
	foreach s {left right bottom} {
		if {![winfo exists .site$s.tabs]} continue
		.site$s.tabs configure -background \
			[dict get $::theme_colors [expr {$s eq $site ? "accent" : "ui.bg"}]]
	}
}

# Tab drag (D35 c3): the same relocation as the right-click menu, by dragging. Press
# records the candidate without activating; a motion past a small threshold starts a
# real drag and previews the drop target (the hovered site, if different, lit with
# the accent); release relocates there, or — if it was really just a click, never
# passing the threshold — activates the tab. An invalid/self drop snaps back.
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

# Lay the editor groups left-to-right inside the .groups panedwindow. In v1 there are
# at most two; each pane -stretches so they share the width, and the panedwindow gives
# a draggable divider between them. Called after a split/unsplit changes ::groups; with
# one group it just fills the center.
proc relayout_groups {} {
	foreach p [.groups panes] { .groups forget $p }
	foreach g $::groups {
		.groups add [gget $g frame] -stretch always -minsize 120
	}
}

# Centre the sash so a fresh split opens 50/50 (Tk otherwise sizes the new pane from its
# requested width, leaving it a sliver). Called only when a split is *created* (add_group)
# — moving tabs between two existing panes never re-lays-out, so a user who has since
# dragged the sash keeps their layout. Runs after idle so the panedwindow has its width.
proc even_split {} {
	if {[llength [.groups panes]] != 2} return
	set w [winfo width .groups]
	if {$w <= 1} return                       ;# not mapped yet (e.g. headless) — skip
	.groups sash place 0 [expr {$w / 2}] 0
}

# Drag the sash to resize the LEFT site (always on the left edge; D35 c1b). The site
# keeps a fixed -width (propagate off), so we recompute it from the pointer measured
# against the TOPLEVEL'S stable edge (not the site's own, which moves as we resize it
# — referencing that fed back on itself and made the panes jump). The toplevel also
# has propagation off (startup), so a wider site shrinks the editor instead of the
# whole window. Clamped so neither side collapses.
proc sash_drag {} {
	set total [winfo width .]
	set min 120
	set max [expr {$total - 200}]
	set w [expr {[winfo pointerx .] - [winfo rootx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.siteleft configure -width $w
}

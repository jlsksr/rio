# rio-gui/extensions.tcl — the Extensions menu and window, and the start-up update check.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The Extensions menu (D130): the installer, then one door per installed extension that
# has something to configure. An extension's own settings are ITS business and live in
# ITS window — rio's Preferences holds only what rio itself owns, including its settings
# ABOUT extensions (update checking, repositories, signing keys), which stay in
# Preferences ▸ Extensions.
# ---------------------------------------------------------------------------
# Extensions that are GUI-side rather than core-side register here at load time, in the
# rio::modes::register idiom: {id label command}. Empty today — every current door comes
# from the provider list below — but the merge is the point: the menu takes rows from
# wherever they come from, so a mode or a theme growing settings later needs no new
# mechanism, only a row.
set ::ext_settings_extra {}

proc ext_settings_register {id label command} {
	dict set ::ext_settings_extra $id [list $label $command]
}

# Every extension with a settings door, as {id label command}, sorted by label. Read
# from the cached provider list, so building the menu costs no round-trip.
proc ext_settings_rows {} {
	set rows {}
	foreach p $::agent_providers {
		set name [dict get $p name]
		if {![provider_has_settings $name]} continue
		lappend rows [list $name [dict get $p label] [list provider_settings_dialog $name]]
	}
	dict for {id v} $::ext_settings_extra {
		lappend rows [list $id [lindex $v 0] [lindex $v 1]]
	}
	return [lsort -index 1 -dictionary $rows]
}

# Past this many doors the menu would be a list rather than a menu, so it becomes one:
# D92 holds that no menu in rio is data-driven and unbounded, and this menu is
# data-driven. Keeping that true by construction beats assuming nobody installs many.
set ::ext_settings_menu_max 12

proc extensions_menu_fill {} {
	if {![winfo exists .m.extensions]} return
	.m.extensions delete 0 end
	# "Browse…", not "Extensions…": the menu is already called Extensions and the window
	# it opens is titled Extensions, so the entry names the act instead of stuttering
	# the noun twice on one path.
	.m.extensions add command -label "Browse…" -command extensions_window
	.m.extensions add separator
	set rows [ext_settings_rows]
	if {![llength $rows]} {
		# Never an empty menu: say why there is nothing here rather than look broken.
		.m.extensions add command -label "(no extension settings)" -state disabled
	} elseif {[llength $rows] > $::ext_settings_menu_max} {
		.m.extensions add command -label "Extension settings…" -command ext_settings_pick
	} else {
		foreach row $rows {
			.m.extensions add command -label "[lindex $row 1]…" -command [lindex $row 2]
		}
	}
}

# The overflow door: the same bounded picker Switch to Tab… and Theme… use (D74/D92).
proc ext_settings_pick {} {
	set rows {}
	foreach row [ext_settings_rows] { lappend rows [list [lindex $row 0] [lindex $row 1]] }
	set id [pick_dialog "Extension settings" $rows]
	if {$id eq ""} return
	foreach row [ext_settings_rows] {
		if {[lindex $row 0] eq $id} { eval [lindex $row 2] ; return }
	}
}

# ---------------------------------------------------------------------------
# The Extensions window (D39; Settings in D67, its own top-level menu since
# D130): Extensions ▸ Extensions… — where the user
# browses every configured repository, chooses BETWEEN same-name extensions
# (different authors, different versions — each variant its own line with its
# provenance), installs, and removes. Naming: the WINDOW is "Extensions" (what
# you browse); the SOURCES are "Repositories" (where they come from) — the
# header's `Repositories…` button edits sources.list.
#
# Deliberately a NON-MODAL toplevel (no grab, no tkwait): browsing repositories
# is a side activity, not a question blocking the editor — and this is rio's
# first D35-style tool window, to be re-hosted into a dock site when D35 lands.
# Non-modal means re-entry is real: ::repo_busy guards it — one scan or install
# at a time, action buttons disabled meanwhile (the sequential core_calls pump
# the event loop, so the editor itself stays live throughout).
#
# The list aggregates ONE row per (kind, name); the detail below it lists every
# VARIANT of the selected row. Unknown kinds are listed greyed ("needs a newer
# rio" — the forward-compat contract), dead sources get one honest `!!` row
# each, and an installed extension whose source vanished is synthesized from
# the ledger so Remove always works.
# ---------------------------------------------------------------------------

set ::repo_busy 0     ;# a scan or install is running: action buttons disabled
set ::extw_rows {}    ;# row dicts, index-aligned with the window's listbox

# The host, for PROSE about a repository ("rio.skylm.org signs its extensions") and for
# a columnar summary where one source is the only one on the line. Anywhere the user is
# CHOOSING or CONSENTING between sources — a variant line, the Update All consent, the
# start-up notice — print the whole URL instead: two sources can share a domain and
# differ only in scheme or path, and the host alone hides exactly what tells them apart.
proc host_of {url} {
	if {[regexp -nocase {^https?://([^/]+)} $url -> h]} { return $h }
	return $url
}

# Are two source URLs the same repository? The scheme is only how it is reached (D109):
# a user who moves http://host/rio to https://host/rio keeps their updates, the
# [installed] mark and the "from the repository it was installed from" grouping,
# instead of every installed extension turning foreign overnight.
proc source_same {a b} {
	regsub -nocase {^https?://} $a {} a
	regsub -nocase {^https?://} $b {} b
	return [expr {$a eq $b}]
}

proc extensions_window {} {
	set w .extw
	if {[winfo exists $w]} { raise $w ; focus $w.body.list ; return }
	toplevel $w
	wm title $w "Extensions"
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Header: sources editor, refresh, filter.
	frame $w.hdr -background [dict get $c ui.bg]
	button $w.hdr.repos   -text "Repositories…" -font RioUIFont -command extw_sources_dialog
	button $w.hdr.refresh -text "⟳" -font RioUIFont -command extw_refresh  ;# ⟳ rescan (D27)
	# Update All (D107): apt's `upgrade` beside its `update`. Its label carries the
	# count, and it is disabled at zero — the button itself is the answer to "is
	# anything out of date?", so it must never look clickable when nothing is.
	button $w.hdr.upall -text "Update All" -font RioUIFont -command extw_update_all
	label $w.hdr.flbl -text "Filter:" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.hdr.filter -font RioUIFont -width 18
	ctx_bind_input $w.hdr.filter   ;# (D115)
	pack $w.hdr.repos $w.hdr.refresh $w.hdr.upall -side left -padx {0 4}
	pack $w.hdr.filter $w.hdr.flbl -side right
	bind $w.hdr.filter <KeyRelease> extw_fill

	# The aggregated list: one row per (kind, name), plus the honest failures.
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extw.body.list yview}
	listbox $w.body.list -height 12 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .extw.body.sb .extw.body.list}
	pack $w.body.list -side left -fill both -expand 1
	bind $w.body.list <<ListboxSelect>> extw_select

	# The detail section: every variant of the selected row, with its own
	# Install/Remove — where the user CHOOSES between authors and versions.
	frame $w.det -background [dict get $c ui.bg]

	frame $w.foot -background [dict get $c ui.bg]
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.close -side right

	# A real status bar, not a label sharing the button row: what the window last DID
	# (scanned, installed, removed) is a report, and inline on the window's own
	# background it read as one more line of the detail pane above it. So it takes the
	# Win2000/VS6 form — a sunken strip across the whole bottom edge, below the buttons,
	# always present (empty is a state, a bar that comes and goes jumps the layout).
	label $w.status -anchor w -font RioUIFont -padx 4 -pady 1 \
		-relief sunken -borderwidth 1 \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]

	grid $w.hdr    -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.det    -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.foot   -row 3 -column 0 -sticky we   -padx 8 -pady {2 6}
	grid $w.status -row 4 -column 0 -sticky we
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	bind $w <Escape> [list destroy $w]

	extw_refresh
	focus $w.body.list
}

proc extw_status {text} {
	if {[winfo exists .extw.status]} { .extw.status configure -text $text }
}

# Toggle the busy guard: while a scan or install runs, every action button in
# the window is disabled — re-entry through a second click is the non-modal
# window's real hazard, and this is its one gate.
proc extw_busy {on} {
	set ::repo_busy $on
	if {![winfo exists .extw]} return
	set st [expr {$on ? "disabled" : "normal"}]
	foreach b {.extw.hdr.repos .extw.hdr.refresh} { $b configure -state $st }
	extw_upall_sync
	foreach f [winfo children .extw.det] {
		# The cross-source checkbutton sits directly in the detail frame; the
		# Install/Update/Remove buttons sit one level deeper, in a variant's row.
		if {[winfo class $f] eq "Checkbutton"} { $f configure -state $st ; continue }
		foreach ch [winfo children $f] {
			if {[winfo class $ch] eq "Button"} { $ch configure -state $st }
		}
	}
}

# The Update All button's label and state: the count is part of the label, so the
# window answers "anything out of date?" without a selection or a click.
proc extw_upall_sync {} {
	if {![winfo exists .extw.hdr.upall]} return
	set n [dict size $::ext_updates]
	.extw.hdr.upall configure \
		-text [expr {$n ? "Update All ($n)" : "Update All"}] \
		-state [expr {$n && !$::repo_busy ? "normal" : "disabled"}]
}

proc extw_refresh {} {
	if {$::repo_busy} return
	extw_busy 1
	# What the core holds: its provider-api ceiling (D66) — so a repo provider that
	# needs a newer rio greys before an install even reaches the core — and the
	# installed version of each provider in its store, which for a provider outranks
	# this GUI's ledger (D107). Best-effort: an old core with no provider.list leaves
	# the default, and every provider then lists as api 1 (what such a core could
	# load anyway).
	ext_core_providers_refresh
	# Which providers this core has actually LOADED, which is a different question from
	# which are in its store — and the one the detail pane's settings button turns on.
	agent_providers_refresh
	repo_scan_all {apply {{src n total} {
		extw_status "fetching [host_of $src] ($n/$total)…"
		update idletasks
	}}}
	extw_busy 0
	set msg "[llength $::repo_variants] extension(s) from [dict size $::repo_srcinfo] repositories"
	if {[dict size $::ext_updates]} { append msg " — [dict size $::ext_updates] update(s)" }
	extw_status $msg
	extw_fill
}

# Update All from the window: one consent for the batch (ext_update_all), then a
# rescan — an update can change what a source offers next (a payload list, a
# provider's api), and the row marks must come from fresh manifests, not from the
# ones that were on screen when the button was pressed.
proc extw_update_all {} {
	if {$::repo_busy} return
	if {![dict size $::ext_updates]} return
	set n [dict size $::ext_updates]
	extw_busy 1
	extw_status "updating $n extension(s)…"
	set done [ext_update_all]
	extw_busy 0
	extw_status [expr {$done ? "updated $done of $n extension(s)" : "nothing updated"}]
	if {$done} { extw_refresh } else { extw_fill }
}

# Aggregate the scan + ledger into display rows: one per (kind, name), sorted;
# ledger-only entries (source offline or de-configured) synthesized so Remove
# still works; one `!!` row per dead source at the bottom.
proc extw_rows_build {} {
	set bykey {}
	foreach v $::repo_variants {
		dict lappend bykey "[dict get $v kind]/[dict get $v name]" $v
	}
	# Installed, but no source lists it: the ledger (or, for a provider, the core —
	# D107) speaks for it, so Remove always works even when the repository is gone.
	dict for {key cur} $::ext_installed {
		if {[dict exists $bykey $key]} continue
		lassign [split $key /] kind name
		set e [expr {[dict exists $::ext_ledger $key] ? [dict get $::ext_ledger $key] : {}}]
		dict set bykey $key [list [dict create \
			source [dict get $cur source] \
			dir [expr {[dict exists $e dir] ? [dict get $e dir] : ""}] \
			name $name kind $kind version [dict get $cur version] author "" \
			description "installed; its repository is not configured or unreachable" \
			files [expr {[dict exists $e files] ? [dict get $e files] : {}}] offline 1]]
	}
	set rows {}
	foreach key [lsort [dict keys $bykey]] {
		lassign [split $key /] kind name
		set vars [dict get $bykey $key]
		set desc ""
		foreach v $vars {
			if {[dict get $v description] ne ""} { set desc [dict get $v description] ; break }
		}
		lappend rows [dict create kind $kind name $name key $key \
			variants $vars desc $desc]
	}
	foreach d $::repo_dead {
		lappend rows [dict create dead 1 url [lindex $d 0] error [lindex $d 1] \
			code [lindex $d 2] newkey [lindex $d 3]]
	}
	return $rows
}

# Why a source produced no extensions, in the few words a list row has. Everything
# past `unreachable` is a signature refusal (D118) — the detail pane below carries
# the sentence, and for a key waiting to be confirmed or one that changed (D119) the
# way to act on it.
proc dead_phrase {code} {
	switch -- $code {
		untrusted_cert  { return "certificate not trusted" }
		key_unconfirmed { return "signing key not confirmed" }
		key_changed     { return "signing key changed" }
		sig_bad         { return "signature doesn't verify" }
		sig_missing     { return "signature missing" }
		sig_dropped     { return "no longer signed" }
		sig_no_tool     { return "can't check the signature" }
		hash_mismatch   { return "files don't match the signature" }
	}
	return "unreachable"
}

# Fill the listbox from the rows, applying the filter; keep the selection on
# the same (kind, name) across a refill if it survived it.
proc extw_fill {} {
	if {![winfo exists .extw.body.list]} return
	set filter [string tolower [string trim [.extw.hdr.filter get]]]
	set keep ""
	set sel [.extw.body.list curselection]
	if {$sel ne "" && [dict exists [lindex $::extw_rows $sel] key]} {
		set keep [dict get [lindex $::extw_rows $sel] key]
	}
	set ::extw_rows {}
	.extw.body.list delete 0 end
	set c $::theme_colors
	foreach row [extw_rows_build] {
		if {[dict exists $row dead]} {
			if {$filter ne "" && ![string match *$filter* [string tolower [dict get $row url]]]} continue
			lappend ::extw_rows $row
			.extw.body.list insert end "!! [dict get $row url] — [dead_phrase [dict get $row code]]"
			.extw.body.list itemconfigure end -foreground [dict get $c error]
			continue
		}
		if {$filter ne "" && ![string match *$filter* \
			[string tolower "[dict get $row name] [dict get $row kind] [dict get $row desc]"]]} continue
		lappend ::extw_rows $row
		set vars [dict get $row variants]
		if {[llength $vars] > 1} {
			set from "[llength $vars] sources"
		} else {
			set from [host_of [dict get [lindex $vars 0] source]]
			if {[dict exists [lindex $vars 0] offline]} { append from " (offline)" }
		}
		# The installed mark carries the version comparison (D107): what you have, and
		# what a repository now offers instead. A version that doesn't follow the semver
		# rule says so rather than being silently left out of the comparison.
		set marks ""
		set key [dict get $row key]
		set update [dict exists $::ext_updates $key]
		if {[dict exists $::ext_installed $key]} {
			set cur [dict get [dict get $::ext_installed $key] version]
			if {$update} {
				append marks " \[$cur → [dict get [dict get $::ext_updates $key] to]\]"
			} elseif {[ext_ver_parse $cur] eq ""} {
				append marks " \[installed $cur — version not comparable\]"
			} else {
				append marks " \[installed $cur\]"
			}
		}
		if {![ext_row_installable $row]} { append marks " (needs a newer rio)" }
		.extw.body.list insert end \
			[format "%-16s %-8s %s%s" [dict get $row name] [dict get $row kind] $from $marks]
		if {![ext_row_installable $row]} {
			.extw.body.list itemconfigure end -foreground [dict get $c gutter.fg]
		} elseif {$update} {
			.extw.body.list itemconfigure end -foreground [dict get $c accent]
		}
	}
	if {$keep ne ""} {
		for {set i 0} {$i < [llength $::extw_rows]} {incr i} {
			if {[dict exists [lindex $::extw_rows $i] key]
					&& [dict get [lindex $::extw_rows $i] key] eq $keep} {
				.extw.body.list selection set $i
				break
			}
		}
	}
	extw_upall_sync
	extw_select
}

# Rebuild the detail section for the selected row: the extension's header line,
# then one line per variant — `version by author — source-host` with Install,
# or [installed] + Remove on the variant that is in place. An installed version
# no longer listed by its source gets its own honest line.
#
# D107 adds the version comparison to each variant line: the one that would
# UPDATE what is installed says so and its button reads Update; one that is
# behind says so and keeps a plain Install (a downgrade stays possible, it just
# never happens by accident). Below the header, an installed row carries the
# cross-source checkbutton — the per-extension opt-in that lets a repository
# OTHER than the one it came from count as an update at all.
proc extw_select {} {
	set det .extw.det
	if {![winfo exists $det]} return
	foreach ch [winfo children $det] { destroy $ch }
	set c $::theme_colors
	set sel [.extw.body.list curselection]
	if {$sel eq "" || $sel >= [llength $::extw_rows]} return
	set row [lindex $::extw_rows $sel]
	# Bound long text to the list's width so a wordy description word-wraps rather
	# than stretching this auto-sized window. reqwidth is the list's requested pixel
	# width (from -width 72), stable even before the window is mapped; `wrapb` leaves
	# room for a variant row's Install/Remove button.
	set wrap  [expr {[winfo reqwidth .extw.body.list] - 12}]
	set wrapb [expr {$wrap - 90}]
	if {[dict exists $row dead]} {
		label $det.err -anchor w -justify left -font RioUIFont -wraplength $wrap \
			-text "[dict get $row url]\n[dict get $row error]" \
			-background [dict get $c ui.bg] -foreground [dict get $c error]
		pack $det.err -fill x
		# A refused certificate is the one dead source the user can do something about
		# here: look at it, and accept it if it is theirs (D111). Offered for an https
		# source only — an http one refused on a redirect has no certificate of its own
		# to show, and its message already names the certificate that was refused.
		if {[dict get $row code] eq "untrusted_cert" && [regexp -nocase {^https://} [dict get $row url]]} {
			button $det.review -text "Review certificate…" -font RioUIFont \
				-state [expr {$::repo_busy ? "disabled" : "normal"}] \
				-command [list extw_cert_review [dict get $row url] [dict get $row error]]
			pack $det.review -anchor w -pady {4 0}
		}
		# A signing key waiting to be confirmed (D119) or a rotated one (D118) is the
		# other dead source the user can act on, and the act is the same shape: look at
		# what is being asked for, then say yes to that one thing.
		if {[dict get $row code] in {key_unconfirmed key_changed} && [dict get $row newkey] ne ""} {
			button $det.keyreview -text "Review signing key…" -font RioUIFont \
				-state [expr {$::repo_busy ? "disabled" : "normal"}] \
				-command [list extw_key_review [dict get $row url] [dict get $row newkey]]
			pack $det.keyreview -anchor w -pady {4 0}
		}
		return
	}
	set head "[dict get $row name] — [dict get $row kind]"
	if {[dict get $row desc] ne ""} { append head " — [dict get $row desc]" }
	label $det.head -anchor w -justify left -wraplength $wrap -font RioUIFont -text $head \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	pack $det.head -fill x -pady {0 2}
	set key [dict get $row key]
	set entry ""
	if {[dict exists $::ext_installed $key]} { set entry [dict get $::ext_installed $key] }
	set st [expr {$::repo_busy ? "disabled" : "normal"}]
	# An installed provider: say whether it is actually running, and if it is, offer its
	# own settings window from here as well as from the Extensions menu (D130) — the
	# window that just installed it is the likeliest place to want it. Same predicate as
	# the menu's, so the two can never disagree about who has a window: a keyed provider
	# earns one on its key alone, even declaring no options. A provider installs
	# core-side and is sourced only at the next core start (D66), so "installed" and
	# "live" are genuinely different states — and the window that just installed it is
	# where saying so is most use. The test is the REGISTERED list, never the ledger:
	# asking a core about a provider it has not loaded gets nothing to show.
	if {$entry ne "" && [dict get $row kind] eq "provider"} {
		set pname [dict get $row name]
		if {[provider_has_settings $pname]} {
			button $det.settings -text "[agent_provider_label $pname] settings…" \
				-font RioUIFont -state $st \
				-command [list provider_settings_dialog $pname]
			pack $det.settings -anchor w -pady {2 2}
		} elseif {[agent_provider_entry $pname] eq ""} {
			label $det.restart -anchor w -justify left -wraplength $wrap -font RioUIFont \
				-text "Restart rio to use this provider." \
				-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
			pack $det.restart -fill x -pady {2 2}
		}
	}
	# The cross-source opt-in, on installed rows only: it is a statement about THIS
	# extension's identity across repositories, so it belongs on the extension, not in
	# Preferences. Off by default (D107).
	if {$entry ne "" && [dict exists $::ext_ledger $key]} {
		set ::extw_anysource [ext_anysource $key]
		checkbutton $det.anysrc -variable ::extw_anysource -state $st \
			-text "Also accept updates from other repositories" \
			-command [list extw_anysource_toggle $key] \
			-font RioUIFont -anchor w -wraplength $wrap \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
			-selectcolor [dict get $c ui.bg]
		pack $det.anysrc -fill x -pady {0 2}
	}
	set i 0
	set matched 0
	foreach v [dict get $row variants] {
		set f [frame $det.v$i -background [dict get $c ui.bg]]
		set line "  [dict get $v version]"
		if {[dict get $v author] ne ""} { append line " by [dict get $v author]" }
		append line " — [dict get $v source]"
		# Where the choice between two sources is actually made, so the thing that
		# distinguishes them is stated here (D118). An offline row has no source to
		# say anything about.
		if {![dict exists $v offline]} {
			append line " — [sig_mark [expr {[dict exists $v sig] ? [dict get $v sig] : "unsigned"}]]"
		}
		set this_installed [expr {$entry ne "" \
			&& [source_same [dict get $v source] [dict get $entry source]] \
			&& [dict get $v version] eq [dict get $entry version]}]
		# How this variant relates to what is installed. Only ever stated when both
		# versions follow the semver rule — otherwise rio makes no claim (D107).
		set is_update [expr {[ext_variant_update $v] ne ""}]
		if {!$this_installed && !$is_update && $entry ne "" && ![dict exists $v offline]
				&& [source_same [dict get $v source] [dict get $entry source]]
				&& [ext_ver_cmp [dict get $v version] [dict get $entry version]] eq "-1"} {
			append line "  (older than the installed [dict get $entry version])"
		}
		label $f.l -anchor w -justify left -wraplength $wrapb -font RioUIFont -text $line \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		if {$this_installed} {
			set matched 1
			label $f.mark -font RioUIFont -text "\[installed\]" \
				-background [dict get $c ui.bg] -foreground [dict get $c accent]
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm $f.mark -side right -padx 2
		} elseif {[dict exists $v offline]} {
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm -side right -padx 2
		} elseif {[ext_variant_installable $v]} {
			# Update, not Install, when this is the newer version of what you already
			# have — same act, but the button says which act it is.
			button $f.in -text [expr {$is_update ? "Update" : "Install"}] \
				-font RioUIFont -state $st -command [list extw_install $sel $i]
			pack $f.in -side right -padx 2
		}
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
		incr i
	}
	if {$entry ne "" && !$matched && ![dict exists [lindex [dict get $row variants] 0] offline]} {
		set f [frame $det.inst -background [dict get $c ui.bg]]
		label $f.l -anchor w -justify left -wraplength $wrapb -font RioUIFont \
			-text "  installed: [dict get $entry version] — [dict get $entry source] (no longer listed there)" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $f.rm -text Remove -font RioUIFont -state $st \
			-command [list extw_remove [dict get $row kind] [dict get $row name]]
		pack $f.rm -side right -padx 2
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
	}
}

proc extw_install {rowidx vidx} {
	if {$::repo_busy} return
	set row [lindex $::extw_rows $rowidx]
	set v [lindex [dict get $row variants] $vidx]
	extw_busy 1
	extw_status "installing [dict get $row name]…"
	set done [ext_install $v]
	extw_busy 0
	extw_status [expr {$done ? "installed [dict get $row name] [dict get $v version]" : "not installed"}]
	extw_fill
}

# Flip one extension's cross-source flag and repaint: the count in Update All and
# the row's mark both change with it, so the effect of the checkbutton is visible
# in the same window without a rescan (the variants are already in hand).
set ::extw_anysource 0   ;# the detail checkbutton's variable, per selected row
proc extw_anysource_toggle {key} {
	ext_anysource_set $key $::extw_anysource
	extw_fill
}

proc extw_remove {kind name} {
	if {$::repo_busy} return
	extw_busy 1
	extw_status "removing $name…"
	ext_remove $kind $name
	extw_busy 0
	extw_status "removed $name"
	extw_fill
}

# ---------------------------------------------------------------------------
# The start-up check (D107) — rio's `apt update` at boot, OFF by
# default: a fresh rio makes no network request it was not asked to make, and
# the request is the CORE's anyway (repo.fetch), which on a remote core means
# someone else's machine.
#
# Deferred on a timer, and deferred again while an op is in flight or the
# Extensions window is scanning — the rule fs_changed_settle follows: never
# start a core call from a timer inside another op's round trip. Every failure
# is silent (a dead source is already one honest row in the window); the only
# thing this is allowed to interrupt the user with is a genuine finding.
# ---------------------------------------------------------------------------
set ::ext_check_updates 0    ;# the preference (prefs.json `check_updates`)
set ::ext_check_delay 1500   ;# ms after boot; long enough for the window to settle
set ::ext_check_after ""     ;# pending check timer; "" while none is armed

proc ext_check_arm {} {
	if {!$::ext_check_updates} return
	if {$::ext_check_after ne ""} return
	set ::ext_check_after [after $::ext_check_delay ext_startup_check]
}

proc ext_startup_check {} {
	set ::ext_check_after ""
	if {!$::ext_check_updates} return
	if {[array size ::pending] || $::repo_busy} {
		set ::ext_check_after [after $::ext_check_delay ext_startup_check]
		return
	}
	if {![llength [sources_load]]} return
	set ::repo_busy 1
	catch {
		ext_core_providers_refresh
		repo_scan_all
	}
	set ::repo_busy 0
	if {[dict size $::ext_updates]} { ext_update_dialog }
}

# What the check found. A plain toplevel rather than a tk_messageBox because it
# carries a checkbutton — and "don't ask again" is the honest escape from a
# start-up notification: it turns the preference off, which means checking
# becomes the user's own business in the Extensions window, and says so.
#
# NO grab and no tkwait: this reports, it does not ask. Boot must not block on
# it, and a modal a headless run can reach is exactly the hazard the dialog
# guard at the foot of this file exists to prevent.
proc ext_update_dialog {} {
	set w .extupd
	destroy $w
	toplevel $w
	wm title $w "rio — extension updates"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set n [dict size $::ext_updates]
	label $w.head -anchor w -justify left -font RioUIFont \
		-text "[expr {$n == 1 ? "One extension has" : "$n extensions have"}] a newer version available:" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	set lines {}
	foreach key [lsort [dict keys $::ext_updates]] {
		set u [dict get $::ext_updates $key]
		lassign [split $key /] kind name
		lappend lines [format "    %-16s %s → %s    %s" $name \
			[dict get $u from] [dict get $u to] [dict get [dict get $u variant] source]]
	}
	label $w.list -anchor w -justify left -font RioUIFont -text [join $lines "\n"] \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	checkbutton $w.stop -variable ::ext_check_updates -onvalue 0 -offvalue 1 \
		-text "Don't check for updates at start-up" -command ext_check_pref_save \
		-font RioUIFont -anchor w \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -activeforeground [dict get $c ui.fg] \
		-selectcolor [dict get $c ui.bg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ext   -text "Extensions…" -font RioUIFont \
		-command [list apply {{w} { destroy $w ; extensions_window }} $w]
	button $w.btns.close -text "Close" -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.ext   -side right -padx {0 4}
	grid $w.head -row 0 -column 0 -sticky we -padx 12 -pady {12 4}
	grid $w.list -row 1 -column 0 -sticky we -padx 12
	grid $w.stop -row 2 -column 0 -sticky w  -padx 12 -pady {10 4}
	grid $w.btns -row 3 -column 0 -sticky we -padx 12 -pady {4 12}
	grid columnconfigure $w 0 -weight 1
	bind $w <Escape> [list destroy $w]
	focus $w.btns.close
}

# The preference is one flag, written through the same prefs.json as every other
# view setting — so both of its doors (this dialog's checkbutton and the
# Preferences pane) record the same thing.
proc ext_check_pref_save {} { prefs_save }

# The compact sources editor behind `Repositories…`: the URLs of sources.list
# in a listbox, Remove for the selected one, an entry + Add below. Writes
# sources.list on every change (it IS the hand-editable file — this dialog is
# just a convenience over it). Modal is fine here: it's a small focused edit,
# not a browsing surface. Closing refreshes the Extensions window's scan.
proc extw_sources_dialog {} {
	set w .extsrc
	destroy $w
	toplevel $w
	wm title $w "Repositories"
	# Reachable from the Extensions window and from Preferences ▸ Extensions (D107),
	# so the master is whichever is actually there.
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	# Hint text is muted (gutter.fg), so static help never reads as an interactive
	# element; the list below carries a solid border for the same reason — the
	# selectable repository URLs must look distinct from this sentence (D68).
	label $w.hint -anchor w -justify left -font RioUIFont \
		-text "Each repository is a plain directory served over http:// or https:// (see CONTRIBUTING.md to host one)." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extsrc.body.list yview}
	listbox $w.body.list -height 8 -width 60 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] \
		-selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .extsrc.body.sb .extsrc.body.list}
	pack $w.body.list -side left -fill both -expand 1
	frame $w.add -background [dict get $c ui.bg]
	entry $w.add.url -font RioUIFont -width 44
	ctx_bind_input $w.add.url   ;# (D115)
	button $w.add.add -text Add -font RioUIFont -command extw_source_add
	pack $w.add.url -side left -fill x -expand 1
	pack $w.add.add -side left -padx {4 0}
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Remove selected" -font RioUIFont -command extw_source_remove
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body -row 1 -column 0 -sticky nsew -padx 8
	grid $w.add  -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.btns -row 3 -column 0 -sticky we   -padx 8 -pady {2 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	foreach u [sources_load] { $w.body.list insert end $u }
	bind $w.add.url <Return> extw_source_add
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.add.url
	tkwait window $w
	# Only rescan when there is a window to repaint: opened from Preferences, this
	# dialog is a plain edit of sources.list and must not reach for the network.
	if {[winfo exists .extw]} { extw_refresh }
}

proc extw_source_add {} {
	set url [string trim [.extsrc.add.url get]]
	if {$url eq ""} return
	# http and https are both first-class (D109): the scheme is the user's choice, and
	# nothing here nudges one over the other.
	if {![regexp -nocase {^https?://} $url]} {
		report_error "A repository URL starts with http:// or https:// — got: $url"
		return
	}
	set urls [sources_load]
	if {$url ni $urls} {
		lappend urls $url
		sources_save $urls
		.extsrc.body.list insert end $url
	}
	.extsrc.add.url delete 0 end
}

proc extw_source_remove {} {
	set sel [.extsrc.body.list curselection]
	if {$sel eq ""} return
	set url [.extsrc.body.list get $sel]
	sources_save [lsearch -all -inline -not -exact [sources_load] $url]
	.extsrc.body.list delete $sel
}

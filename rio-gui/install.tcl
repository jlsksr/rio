# rio-gui/install.tcl — extensions: what is installed, updates, installing and removing.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# --- what is installed, and what is an update (D107) -----------------

# What is installed: "kind/name" -> {version source}. From the ledger, except
# that for a provider the core's store wins (provider.list, D66): it also
# knows a provider another frontend installed.
# Derived, never written to extensions.json: that file must not record one
# core's answer for another.
proc ext_installed_compute {} {
	set ::ext_installed {}
	dict for {key e} $::ext_ledger {
		dict set ::ext_installed $key [dict create \
			version [dict get $e version] source [dict get $e source]]
	}
	dict for {name p} $::ext_core_providers {
		dict set ::ext_installed provider/$name $p
	}
}

# Ask the core which providers its store holds, and their versions. If the
# call fails, the ledger speaks for providers.
proc ext_core_providers_refresh {} {
	set ::ext_core_providers {}
	set pr [rio_call provider.list {}]
	if {![dict get $pr ok]} return
	if {[dict exists $pr result api_max]} {
		set ::provider_api_max [dict get $pr result api_max]
	}
	if {![dict exists $pr result providers]} return
	foreach p [dict get $pr result providers] {
		if {![dict exists $p name] || ![dict exists $p version]} continue
		# echo is the built-in stub, not an installed extension — it has no source.
		set src [expr {[dict exists $p source] ? [dict get $p source] : ""}]
		if {$src eq ""} continue
		dict set ::ext_core_providers [dict get $p name] \
			[dict create version [dict get $p version] source $src]
	}
}

# Does an extension take updates from repositories other than the one it was
# installed from? Off by default (D107): without a central index, `vi` on
# another host may be a different program. Installing it stays possible.
proc ext_anysource {key} {
	if {![dict exists $::ext_ledger $key]} { return 0 }
	set e [dict get $::ext_ledger $key]
	return [expr {[dict exists $e anysource] && [dict get $e anysource] ? 1 : 0}]
}

proc ext_anysource_set {key on} {
	if {![dict exists $::ext_ledger $key]} return
	dict set ::ext_ledger $key anysource [expr {$on ? 1 : 0}]
	ledger_save
	ext_updates_compute
}

# Is this variant an update to what is installed? Returns the installed
# version it would replace, or "". Not an update: not installed, a version
# that is not semver, the same or a lower version, another source without the
# flag, a variant this rio cannot install.
proc ext_variant_update {v} {
	set key "[dict get $v kind]/[dict get $v name]"
	if {![dict exists $::ext_installed $key]} { return "" }
	if {[dict exists $v offline]} { return "" }
	if {![ext_variant_installable $v]} { return "" }
	set cur [dict get $::ext_installed $key]
	if {![source_same [dict get $v source] [dict get $cur source]] && ![ext_anysource $key]} { return "" }
	if {[ext_ver_cmp [dict get $v version] [dict get $cur version]] != 1} { return "" }
	return [dict get $cur version]
}

# "kind/name" -> {from to variant}: one pending update per extension, the highest
# on offer when several sources qualify (only possible with anysource set).
proc ext_updates_compute {} {
	set ::ext_updates {}
	foreach v $::repo_variants {
		set from [ext_variant_update $v]
		if {$from eq ""} continue
		set key "[dict get $v kind]/[dict get $v name]"
		if {[dict exists $::ext_updates $key]} {
			set have [dict get [dict get $::ext_updates $key] to]
			if {[ext_ver_cmp [dict get $v version] $have] != 1} continue
		}
		dict set ::ext_updates $key [dict create \
			from $from to [dict get $v version] variant $v]
	}
}

# --- installing & removing ----------------------------------------------------

# The kinds this rio can install. Any other kind is listed greyed (D39).
proc ext_kind_known {kind} {
	return [expr {$kind in {syntax mode theme provider}}]
}

proc ext_kind_dir {kind} {
	switch -- $kind {
		syntax { return [hl_user_dir] }
		mode   { return [modes_user_dir] }
	}
	return ""
}

# The versioned contract of a kind, as {manifest-key ceiling default}, or ""
# for a kind without one (D123).
#   provider   provider-api, required: a manifest without it is refused
#   mode       mode-api, default 1: older modes shipped without the key
#   syntax, theme   none
proc ext_kind_api {kind} {
	switch -- $kind {
		provider { return [list provider-api $::provider_api_max ""] }
		mode     { return [list mode-api     $::mode_api_max     1] }
	}
	return ""
}

# Can this rio install the variant? Not an unknown kind, and not one that
# needs a newer contract (`too_new`, set by the scan).
proc ext_variant_installable {v} {
	if {![ext_kind_known [dict get $v kind]]} { return 0 }
	if {[dict exists $v too_new] && [dict get $v too_new]} { return 0 }
	return 1
}

# A row is greyed when none of its variants can be installed here.
proc ext_row_installable {row} {
	foreach v [dict get $row variants] {
		if {[ext_variant_installable $v]} { return 1 }
	}
	return 0
}

# Which other installed extension of this kind owns one of these filenames?
# "" for none. Payloads of one kind share a dir, so a clash would overwrite.
proc ext_file_owner {kind name files} {
	dict for {key e} $::ext_ledger {
		lassign [split $key /] ekind ename
		if {$ekind ne $kind || $ename eq $name} continue
		foreach f $files {
			if {$f in [dict get $e files]} { return $ename }
		}
	}
	return ""
}

# Install one variant. Returns 1 if installed, 0 if not.
#
#   consent ─► fetch every payload ─► write ─► activate ─► ledger
#
# - Nothing is written until every payload has arrived and passed its hash.
# - A failed write is rolled back.
# - `consented`: Update All already asked once for the batch (D107). Only the
#   dialog is skipped.
proc ext_install {variant {consented 0}} {
	dict with variant {}  ;# source dir name kind version author description files
	if {![ext_kind_known $kind]} {
		report_error "'$name' has kind '$kind', which this rio doesn't know — it needs a newer rio."
		return 0
	}
	# The contract level is enforced here, not only greyed in the list
	# (D123): a mode has no core in its path to refuse it.
	if {[dict exists $variant too_new] && [dict get $variant too_new]} {
		lassign [ext_kind_api $kind] _key ceiling
		report_error "'$name' needs $_key [dict get $variant api], but this rio implements\
			$ceiling — it needs a newer rio."
		return 0
	}
	set key $kind/$name
	# Consent: say whether it is data or code, and name the source.
	if {$kind eq "theme"} {
		set what "'$name' is a THEME: colour/font data, parsed and never executed."
	} elseif {$kind eq "provider"} {
		set what "'$name' is an agent PROVIDER: Tcl code that runs inside the rio CORE\
			(which may be a remote or shared host), can receive the API key you enter for\
			it, and makes network requests with it. Install only from a source you trust\
			with your model credentials."
	} else {
		set what "'$name' is Tcl CODE that will run inside your editor with your permissions."
	}
	set msg "Install $kind '$name' $version by $author?\n\n$what\n\nFrom: $source\n[ext_consent_sig_line $source]"
	if {[dict exists $::ext_installed $key]} {
		set old [dict get $::ext_installed $key]
		set msg "$msg\n\nReplaces the installed '$name' [dict get $old version] from [dict get $old source]."
	}
	if {!$consented && [tk_messageBox -icon warning -type yesno -title "rio — install extension" \
			-message $msg] ne "yes"} { return 0 }
	# Refuse a filename another extension owns. A provider has a dir of its
	# own (D66), so no clash there.
	if {$kind ne "provider"} {
		set owner [ext_file_owner $kind $name $files]
		if {$owner ne ""} {
			report_error "Cannot install '$name': its payload would overwrite files owned by the installed $kind '$owner'."
			return 0
		}
	}
	# Fetch everything first. On a signed source each payload is checked
	# against the signed hashes here, before anything is written.
	set signed [expr {[dict get [repo_sig_of $source] state] eq "signed"}]
	set payload {}
	foreach f $files {
		set r [repo_fetch $source/$dir/$f $signed]
		if {![dict get $r ok] || [dict get $r status] != 200} {
			set why [expr {[dict get $r ok] ? "HTTP [dict get $r status]" : [dict get $r error]}]
			report_error "Install of '$name' aborted: $f could not be fetched ($why). Nothing was changed."
			return 0
		}
		if {$signed && ![repo_file_ok $source $dir/$f [fetch_hash $r]]} {
			report_error "Install of '$name' aborted: $dir/$f is not the file this repository's\
				signature vouches for. Refresh the list — if the publisher re-uploaded without\
				re-signing, the list you are looking at is older than the files. Nothing was changed."
			return 0
		}
		dict set payload $f [dict get $r text]
	}
	if {$kind eq "theme"} {
		if {![ext_install_theme $name $payload]} { return 0 }
	} elseif {$kind eq "provider"} {
		if {![ext_install_provider $name $manifest $payload $source]} { return 0 }
	} else {
		if {![ext_install_files $kind $name $payload]} { return 0 }
	}
	# The core's store just changed: record the provider's new version here.
	if {$kind eq "provider"} {
		dict set ::ext_core_providers $name [dict create version $version source $source]
	}
	set entry [dict create \
		source $source dir $dir version $version files $files \
		installed [clock format [clock seconds] -format %Y-%m-%d]]
	# The cross-source flag is the user's: an update keeps it (D107).
	if {[ext_anysource $key]} { dict set entry anysource 1 }
	# Who signed these files, if anyone (D118).
	set sigstate [repo_sig_of $source]
	if {[dict get $sigstate state] eq "signed" && [dict get $sigstate signer] ne ""} {
		dict set entry signed_by [dict get $sigstate signer]
	}
	dict set ::ext_ledger $key $entry
	ledger_save
	ext_installed_compute
	ext_updates_compute
	return 1
}

# Write syntax or mode payloads into the kind's user dir and reload it, so
# the extension is live at once. On failure: files that existed are
# restored, new ones removed.
proc ext_install_files {kind name payload} {
	set dstdir [ext_kind_dir $kind]
	if {$dstdir eq ""} { report_error "No user $kind directory resolvable (no HOME?)." ; return 0 }
	set undo {}
	if {[catch {
		file mkdir $dstdir
		dict for {f text} $payload {
			set p [file join $dstdir $f]
			if {[file exists $p]} {
				set old [open $p r] ; fconfigure $old -encoding utf-8
				lappend undo restore $p [::read $old] ; close $old
			} else {
				lappend undo delete $p ""
			}
			set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
			puts -nonewline $out $text ; close $out
		}
	} err]} {
		foreach {what p text} $undo {
			catch {
				if {$what eq "delete"} { file delete $p } else {
					set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
					puts -nonewline $out $text ; close $out
				}
			}
		}
		report_error "Install of '$name' failed writing files: $err. Rolled back."
		return 0
	}
	ext_reload $kind
	return 1
}

# A theme installs in the core, through theme.put: night.theme becomes the
# theme `night`. The core validates it. On a failure the themes already put
# by this install are deleted again.
proc ext_install_theme {name payload} {
	set put {}
	dict for {f text} $payload {
		set tname [file rootname $f]
		set resp [rio_call theme.put [dict create name $tname text $text]]
		if {![dict get $resp ok]} {
			foreach t $put { catch {rio_call theme.delete [dict create name $t]} }
			report_error "Install of theme '$name' failed at $f: [dict get $resp error message]" \
				[dict get $resp error code]
			return 0
		}
		lappend put $tname
	}
	ext_reload theme
	return 1
}

# A provider installs in the core, through provider.put (D66). The core
# validates the manifest. It is not sourced now: it starts with the next core
# start, and the dialog says so.
proc ext_install_provider {name manifest payload source} {
	set resp [rio_call provider.put [dict create \
		name $name manifest $manifest files $payload source $source]]
	if {![dict get $resp ok]} {
		report_error "Install of provider '$name' failed: [dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	tk_messageBox -icon info -type ok -title "rio — provider installed" \
		-message "Installed the agent provider '$name'.\n\nIt becomes available the next\
			time the rio core starts — restart rio to use it."
	return 1
}

# Remove an installed extension: the files first, the ledger entry last.
proc ext_remove {kind name} {
	set key $kind/$name
	if {![dict exists $::ext_ledger $key]} {
		# A provider the core holds but this ledger does not know (D107):
		# provider.delete needs only the name.
		if {$kind eq "provider" && [dict exists $::ext_core_providers $name]} {
			catch {rio_call provider.delete [dict create name $name]}
			dict unset ::ext_core_providers $name
			ext_installed_compute
			ext_updates_compute
			return 1
		}
		return 0
	}
	set e [dict get $::ext_ledger $key]
	if {$kind eq "theme"} {
		foreach f [dict get $e files] {
			catch {rio_call theme.delete [dict create name [file rootname $f]]}
		}
	} elseif {$kind eq "provider"} {
		catch {rio_call provider.delete [dict create name $name]}
		dict unset ::ext_core_providers $name
	} else {
		set dstdir [ext_kind_dir $kind]
		foreach f [dict get $e files] {
			catch {file delete [file join $dstdir $f]}
		}
	}
	dict unset ::ext_ledger $key
	ledger_save
	ext_installed_compute
	ext_updates_compute
	ext_reload $kind
	return 1
}

# Reload what a kind plugs into, after an install or a removal:
#   syntax   — reload the scanners, repaint every group
#   mode     — reload, refill the menu, re-attach
#   theme    — re-apply the active theme, or the default if it is gone
#   provider — nothing: the core sources it at its next start (D66)
proc ext_reload {kind} {
	switch -- $kind {
		syntax {
			hl_load
			foreach g $::groups { hl_select $g ; hl_reset $g }
		}
		mode {
			modes_load
			modes_menu_fill
			apply_editmode
		}
		theme {
			if {$::theme_name ne "default"} {
				set resp [rio_call theme.get [dict create name $::theme_name]]
				if {[dict get $resp ok]} {
					apply_theme [dict get $resp result]
				} else {
					do_theme default
				}
			}
		}
		provider {
			# Nothing to reload.
		}
	}
}

# Update everything in ::ext_updates under one consent (D107), as apt does:
# each source was trusted at install time. An update from another repository
# is a new trust decision, so the dialog lists those apart.
# ::ext_updates is copied first: each install recomputes it.
proc ext_update_all {} {
	set pending $::ext_updates
	if {![dict size $pending]} { return 0 }
	set same {} ; set foreign {}
	foreach key [lsort [dict keys $pending]] {
		set u [dict get $pending $key]
		lassign [split $key /] kind name
		set v [dict get $u variant]
		set line [format "  %-16s %s → %s   %s (%s)" \
			"$name ($kind)" [dict get $u from] [dict get $u to] \
			[dict get $v source] \
			[sig_mark [expr {[dict exists $v sig] ? [dict get $v sig] : "unsigned"}]]]
		if {[dict exists $::ext_installed $key]
				&& [source_same [dict get $v source] [dict get [dict get $::ext_installed $key] source]]} {
			lappend same $line
		} else {
			lappend foreign $line
		}
	}
	set msg "Update [dict size $pending] extension(s)?\n"
	if {[llength $same]} {
		append msg "\nFrom the repository each was installed from:\n[join $same "\n"]\n"
	}
	if {[llength $foreign]} {
		append msg "\nFrom a DIFFERENT repository than the one it was installed from —\
			a name is not owned by anyone, so check you mean these:\n[join $foreign "\n"]\n"
	}
	append msg "\nEach is re-installed from its repository. Modes and highlighters are code\
		that runs in your editor; providers are code that runs in your core."
	if {[tk_messageBox -icon warning -type yesno -title "rio — update extensions" \
			-message $msg] ne "yes"} { return 0 }
	set done 0
	foreach key [lsort [dict keys $pending]] {
		if {[ext_install [dict get [dict get $pending $key] variant] 1]} { incr done }
	}
	return $done
}

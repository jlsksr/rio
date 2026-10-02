# rio-gui/trust.tcl — certificate exceptions and repository signing keys.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# --- a certificate that doesn't verify (D111) ------------------------------------
#
# As a browser does. A repository whose certificate the core refused lists as
# "certificate not trusted". Review certificate… asks the core for it
# (tls.inspect) and shows what is wrong, the details, and two buttons:
# Go Back (the default) and Accept the Risk and Continue.
# - Accept sends the fingerprint this dialog showed, never a fresh one.
# - Modal. Opened only by the user's click, never by a scan.

# tls.inspect through the core; never raises. Tests stub this proc.
proc tls_inspect {url} {
	set resp [rio_call tls.inspect [dict create url $url]]
	if {[dict get $resp ok]} { return [dict create ok 1 cert [dict get $resp result]] }
	return [dict create ok 0 error [dict get $resp error message]]
}

# The problems tls.inspect reports, as sentences a user can weigh.
proc cert_problem_lines {cert} {
	set host [dict get $cert host]
	set lines {}
	foreach p [dict get $cert problems] {
		switch -- $p {
			changed {
				set lines [linsert $lines 0 "This is NOT the certificate you accepted for $host:[dict get $cert port]. If you didn't replace it on the server, someone may be impersonating it."]
			}
			untrusted {
				lappend lines "It is issued by an authority this system doesn't trust — it is self-signed, or from a private certificate authority."
			}
			expired {
				lappend lines "It expired on [dict get $cert not_after]."
			}
			not_yet_valid {
				lappend lines "It isn't valid until [dict get $cert not_before]."
			}
			name_mismatch {
				set names [join [dict get $cert names] ", "]
				if {$names eq ""} { set names [dict get $cert subject] }
				lappend lines "It was issued for $names, not for $host."
			}
			default {
				lappend lines "It was refused: [join [dict get $cert reasons] {; }]."
			}
		}
	}
	return $lines
}

proc extw_cert_review {url {fetch_error ""}} {
	if {$::repo_busy} return
	extw_busy 1
	extw_status "getting the certificate of [host_of $url]…"
	update idletasks
	set r [tls_inspect $url]
	extw_busy 0
	extw_status ""

	set w .extcert
	destroy $w
	toplevel $w
	wm title $w "Certificate not trusted"
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set wrap 460
	set ::extw_cert_choice ""
	set cert [expr {[dict get $r ok] ? [dict get $r cert] : {}}]
	set askable [expr {$cert ne "" && [llength [dict get $cert problems]] && ![dict get $cert accepted]}]

	frame $w.btns -background [dict get $c ui.bg]
	if {$askable} {
		set origin "[dict get $cert host]:[dict get $cert port]"
		label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont \
			-text "rio can't confirm that $origin is the server it claims to be. Someone could be impersonating it — or it is a server whose certificate isn't signed by an authority this system knows, such as your own." \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		pack $w.head -fill x -padx 8 -pady {8 4}
		set i 0
		foreach line [cert_problem_lines $cert] {
			label $w.p$i -anchor w -justify left -wraplength $wrap -font RioUIFont \
				-text "•  $line" -background [dict get $c ui.bg] -foreground [dict get $c error]
			pack $w.p$i -fill x -padx 8 -pady 1
			incr i
		}
		# The details are data: a bordered box (D68), selectable for copying.
		text $w.det -height 6 -width 64 -wrap word -font RioUIFont -relief solid \
			-borderwidth 1 -highlightthickness 0 \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		ctx_bind_view $w.det   ;# Copy / Select All: the fingerprint is the point (D115)
		set names [join [dict get $cert names] ", "]
		foreach {k v} [list "Issued to" [dict get $cert subject] "Names" $names \
				"Issued by" [dict get $cert issuer] \
				"Valid" "[dict get $cert not_before] – [dict get $cert not_after]" \
				"SHA-256" [dict get $cert sha256]] {
			if {$v eq ""} continue
			$w.det insert end [format "%-10s %s\n" $k: $v]
		}
		$w.det delete "end-1c" end
		$w.det configure -state disabled
		pack $w.det -fill x -padx 8 -pady {6 4}
		label $w.hint -anchor w -justify left -wraplength $wrap -font RioUIFont \
			-text "Accept only if you know this is the server's own certificate — for example, compare the SHA-256 fingerprint with the one on the server. rio then trusts exactly this certificate for $origin, and asks again if it ever changes. To trust every server of a private certificate authority instead, add it to the certificate store on the core's host." \
			-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
		pack $w.hint -fill x -padx 8 -pady {2 6}
		button $w.btns.back -text "Go Back" -font RioUIFont -default active \
			-command [list destroy $w]
		button $w.btns.accept -text "Accept the Risk and Continue" -font RioUIFont \
			-command [list apply {{w} { set ::extw_cert_choice accept ; destroy $w }} $w]
		pack $w.btns.back -side right
		pack $w.btns.accept -side left
		set focus $w.btns.back
	} else {
		if {$cert eq ""} {
			set msg "rio couldn't get the certificate: [dict get $r error]"
		} elseif {[dict get $cert accepted]} {
			set msg "This certificate is already accepted for [dict get $cert host]:[dict get $cert port]. Refresh the list to fetch from it."
		} else {
			set msg "The certificate of [dict get $cert host]:[dict get $cert port] verifies, so the refused one belongs to another server — perhaps one this repository redirects to — and rio can't show it here."
		}
		if {$fetch_error ne ""} { append msg "\n\n$fetch_error" }
		label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont -text $msg \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		pack $w.head -fill x -padx 8 -pady {8 6}
		button $w.btns.back -text Close -font RioUIFont -default active -command [list destroy $w]
		pack $w.btns.back -side right
		set focus $w.btns.back
	}
	pack $w.btns -fill x -padx 8 -pady {2 8}
	bind $w <Escape> [list destroy $w]
	bind $w <Return> [list destroy $w]
	catch {grab $w}
	focus $focus
	tkwait window $w

	if {$::extw_cert_choice ne "accept"} return
	set resp [rio_call tls.accept [dict create host [dict get $cert host] \
		port [dict get $cert port] sha256 [dict get $cert sha256] subject [dict get $cert subject]]]
	if {![dict get $resp ok]} {
		report_error "Couldn't accept the certificate: [dict get $resp error message]"
		return
	}
	if {[winfo exists .extw]} { extw_refresh }
}

# --- confirming a signing key (D118, D119) ---------------------------------
#
# For a repository rio has no key for, and for one whose key changed. Either
# may be the publisher or an impostor, and rio cannot tell: it shows the
# fingerprints and asks. It trusts the key this dialog showed, never a fresh
# one.

# sig.fingerprint through the core; "" when there is none.
proc sig_fingerprint {key} {
	set resp [rio_call sig.fingerprint [dict create key $key]]
	if {![dict get $resp ok]} { return "" }
	return [dict get $resp result fingerprint]
}

proc extw_key_review {url newkey} {
	if {$::repo_busy} return
	set old [repo_key_of $url]
	# First sight (D119): the same dialog with one fingerprint, not two.
	set first [expr {$old eq ""}]
	set oldfp [expr {$first ? "" : [sig_fingerprint $old]}]
	set newfp [sig_fingerprint $newkey]
	set when ""
	set sk [source_key $url]
	if {[dict exists $::repo_keys $sk]} { set when [dict get $::repo_keys $sk trusted] }

	set w .extkey
	destroy $w
	toplevel $w
	wm title $w [expr {$first ? "Confirm signing key" : "Signing key changed"}]
	wm transient $w [expr {[winfo exists .extw] ? ".extw" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set wrap 460
	set ::extw_key_choice ""

	if {$first} {
		set headtext "[host_of $url] signs its extensions, and this is the first time rio has seen a key for it. The signature checks out against this key — but that only proves the key signed these files, not that it is the publisher's. Nothing is installed or listed from this repository until you say it is."
	} else {
		set headtext "[host_of $url] is signing its extensions with a different key than the one rio trusted[expr {$when ne "" ? " on $when" : ""}]. If the publisher rotated their key, this is expected — they have no way to tell you inside rio. If they didn't, someone else is answering for this repository."
	}
	label $w.head -anchor w -justify left -wraplength $wrap -font RioUIFont \
		-text $headtext \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	pack $w.head -fill x -padx 8 -pady {8 4}
	# The fingerprints are data: a bordered box (D68), selectable for copying.
	text $w.det -height 5 -width 64 -wrap word -font RioUIFont -relief solid \
		-borderwidth 1 -highlightthickness 0 \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	ctx_bind_view $w.det   ;# Copy / Select All: the fingerprint is the point (D115)
	foreach {k v} [list "Repository" $url \
			"Trusted" [expr {$oldfp ne "" ? $oldfp : $old}] \
			"Offered" [expr {$newfp ne "" ? $newfp : $newkey}]] {
		if {$v eq ""} continue
		$w.det insert end [format "%-11s %s\n" $k: $v]
	}
	$w.det delete "end-1c" end
	$w.det configure -state disabled
	pack $w.det -fill x -padx 8 -pady {6 4}
	if {$first} {
		set hinttext "Confirm this fingerprint away from this connection — the publisher's own page, a release note, a message from them. Anyone who can answer for this repository can offer a key that verifies; only the publisher can tell you which one is theirs. rio then trusts exactly this key here, and asks again if it ever changes. Every key it trusts is listed under Preferences ▸ Extensions ▸ Repository signing keys…, where forgetting one puts that repository back to this question."
	} else {
		set hinttext "Trust the new key only if you can confirm it away from this connection — the publisher's own page, a release note, a message from them. rio then trusts exactly this key for this repository, and asks again if it ever changes. Every key it trusts is listed under Preferences ▸ Extensions ▸ Repository signing keys…, where forgetting one puts that repository back to being asked about."
	}
	label $w.hint -anchor w -justify left -wraplength $wrap -font RioUIFont \
		-text $hinttext \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	pack $w.hint -fill x -padx 8 -pady {2 6}
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.back -text "Go Back" -font RioUIFont -default active \
		-command [list destroy $w]
	button $w.btns.trust -text [expr {$first ? "Trust This Key" : "Trust the New Key"}] \
		-font RioUIFont \
		-command [list apply {{w} { set ::extw_key_choice trust ; destroy $w }} $w]
	pack $w.btns.back -side right
	pack $w.btns.trust -side left
	pack $w.btns -fill x -padx 8 -pady {2 8}
	bind $w <Escape> [list destroy $w]
	bind $w <Return> [list destroy $w]
	catch {grab $w}
	focus $w.btns.back
	tkwait window $w

	if {$::extw_key_choice ne "trust"} return
	repo_key_trust $url $newkey
	if {[winfo exists .extw]} { extw_refresh }
}

# Preferences ▸ Network ▸ Accepted certificates…: every exception the core
# holds (tls.accepted), and a way to remove one (D111).
proc certs_dialog {} {
	set w .certs
	destroy $w
	toplevel $w
	wm title $w "Accepted certificates"
	wm transient $w [expr {[winfo exists .prefs] ? ".prefs" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -wraplength 480 -font RioUIFont \
		-text "Certificates you accepted although they did not verify. Each is trusted only on its own host and port, and only while the server presents that exact certificate. They are kept in certificates.conf on the core's host." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.certs.body.list yview}
	listbox $w.body.list -height 6 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .certs.body.sb .certs.body.list}
	pack $w.body.list -side left -fill both -expand 1
	label $w.status -anchor w -justify left -wraplength 480 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c error]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Remove selected" -font RioUIFont -command certs_remove
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint   -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.status -row 2 -column 0 -sticky we   -padx 8
	grid $w.btns   -row 3 -column 0 -sticky we   -padx 8 -pady {4 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	certs_fill
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
}

set ::certs_rows {}   ;# the exceptions behind .certs.body.list, in its order

proc certs_fill {} {
	if {![winfo exists .certs]} return
	.certs.body.list delete 0 end
	set ::certs_rows {}
	set resp [rio_call tls.accepted {}]
	# The call pumps the event loop, and the dialog may have been closed meanwhile.
	if {![winfo exists .certs]} return
	if {![dict get $resp ok]} {
		.certs.status configure -text "The core couldn't list accepted certificates: [dict get $resp error message]"
		return
	}
	.certs.status configure -text ""
	foreach e [dict get $resp result exceptions] {
		lappend ::certs_rows $e
		set line "[dict get $e host]:[dict get $e port]"
		if {[dict get $e subject] ne ""} { append line "  —  [dict get $e subject]" }
		append line "  —  SHA-256 [string range [dict get $e sha256] 0 22]…"
		if {[dict get $e accepted] ne ""} { append line "  (accepted [dict get $e accepted])" }
		.certs.body.list insert end $line
	}
}

proc certs_remove {} {
	set sel [.certs.body.list curselection]
	if {$sel eq ""} return
	set e [lindex $::certs_rows $sel]
	set resp [rio_call tls.forget [dict create host [dict get $e host] port [dict get $e port]]]
	if {![winfo exists .certs]} return
	if {![dict get $resp ok]} {
		.certs.status configure -text "Couldn't remove it: [dict get $resp error message]"
		return
	}
	certs_fill
}

# Preferences ▸ Extensions ▸ Repository signing keys…: every key the user
# confirmed, and a way to forget one (D118). Built like certs_dialog.
# - The keys are the GUI's: repository-keys.conf beside sources.list.
# - Forget puts the repository back behind the question: it is refused until
#   a key is confirmed (D119). The built-in key is withdrawn, not deleted;
#   see repo_keys_forget.
proc repo_keys_dialog {} {
	set w .repokeys
	destroy $w
	toplevel $w
	wm title $w "Repository signing keys"
	wm transient $w [expr {[winfo exists .prefs] ? ".prefs" : "."}]
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -wraplength 520 -font RioUIFont \
		-text "The signing key you have confirmed for each extension repository. A repository that later signs with a different key is refused until you review that one too. Forgetting a key does not just clear a note: rio asks about that repository again the next time it is scanned, and installs nothing from it until you answer. The scheme is left off on purpose — moving a repository from http:// to https:// is a change of route, not of publisher. They are kept in repository-keys.conf beside your sources list." \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.repokeys.body.list yview}
	listbox $w.body.list -height 6 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 1 -relief solid -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c accent] -selectforeground [dict get $c ui.bg] \
		-yscrollcommand {autoscroll .repokeys.body.sb .repokeys.body.list}
	pack $w.body.list -side left -fill both -expand 1
	bind $w.body.list <<ListboxSelect>> repo_keys_sel
	# Muted, not the error colour: it explains a row or reports a Forget.
	label $w.status -anchor w -justify left -wraplength 520 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Forget selected" -font RioUIFont -command repo_keys_forget
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint   -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body   -row 1 -column 0 -sticky nsew -padx 8
	grid $w.status -row 2 -column 0 -sticky we   -padx 8 -pady {4 0}
	grid $w.btns   -row 3 -column 0 -sticky we   -padx 8 -pady {4 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	repo_keys_fill
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.body.list
	tkwait window $w
}

set ::repo_keys_rows {}   ;# the keys behind .repokeys.body.list, in its order

proc repo_keys_fill {} {
	if {![winfo exists .repokeys]} return
	.repokeys.body.list delete 0 end
	set ::repo_keys_rows {}
	set rows {}
	dict for {src e} $::repo_keys {
		# A section without a key lists nothing. The withdrawn built-in key
		# gets its row below.
		if {[dict get $e key] eq ""} continue
		lappend rows [dict create src $src key [dict get $e key] \
			when [dict get $e trusted] builtin 0 withdrawn 0]
	}
	# rio's own key is trusted without a stored entry, so it gets a row here,
	# while its repository is in the sources list. Withdrawn, it is still
	# shown (D119).
	set seed [source_key $::default_repo]
	set gone [expr {[dict exists $::repo_keys $seed]
		&& [dict get $::repo_keys $seed key] eq ""}]
	if {![dict exists $::repo_keys $seed] || $gone} {
		foreach u [sources_load] {
			if {![source_same $u $::default_repo]} continue
			lappend rows [dict create src $seed key $::default_repo_key \
				when "" builtin 1 withdrawn $gone]
			break
		}
	}
	foreach row $rows {
		# The call runs the event loop: the window may be gone afterwards.
		set fp [sig_fingerprint [dict get $row key]]
		if {![winfo exists .repokeys]} return
		if {$fp eq ""} {
			# No fingerprint (no ssh-keygen): show the start of the key.
			set k [dict get $row key]
			set fp "[lindex $k 0] [string range [lindex $k 1] 0 15]…"
		}
		set line "[dict get $row src]  —  $fp"
		if {[dict get $row builtin]} {
			append line [expr {[dict get $row withdrawn]
				? "  (built in, withdrawn)" : "  (built in)"}]
		} elseif {[dict get $row when] ne ""} {
			append line "  (trusted [dict get $row when])"
		}
		lappend ::repo_keys_rows $row
		.repokeys.body.list insert end $line
	}
	if {$::repo_keys_rows eq ""} {
		.repokeys.status configure -text "You haven't confirmed a signing key for any repository yet. An unsigned repository has no key to list, and a signed one is refused until its key is confirmed."
	}
}

# Explain the built-in row when it is selected: its Forget withdraws the key.
proc repo_keys_sel {} {
	if {![winfo exists .repokeys]} return
	set sel [.repokeys.body.list curselection]
	set t ""
	if {$sel ne ""} {
		set row [lindex $::repo_keys_rows $sel]
		if {[dict get $row builtin] && [dict get $row withdrawn]} {
			set t "You have withdrawn the key rio ships with for its own repository. rio now asks about that repository's key like any other's — confirming one records it here."
		} elseif {[dict get $row builtin]} {
			set t "rio ships with this key for its own repository, so it is the one key you were never asked about. Forget withdraws it: rio then asks about this repository too, the next time it is scanned."
		}
	}
	.repokeys.status configure -text $t
}

proc repo_keys_forget {} {
	set sel [.repokeys.body.list curselection]
	if {$sel eq ""} return
	set row [lindex $::repo_keys_rows $sel]
	if {[dict get $row builtin]} {
		if {[dict get $row withdrawn]} { repo_keys_sel ; return }
		# The built-in key has no entry to delete. Withdrawing it writes a
		# section without a key (D119).
		dict set ::repo_keys [dict get $row src] [dict create key "" trusted "" \
			forgotten [clock format [clock seconds] -format %Y-%m-%d]]
		repo_keys_save
		repo_keys_fill
		if {![winfo exists .repokeys]} return
		.repokeys.status configure -text "rio has withdrawn its built-in key for [dict get $row src]. The next scan of that repository asks you to confirm whatever key it publishes, and installs nothing from it until you do."
		return
	}
	dict unset ::repo_keys [dict get $row src]
	repo_keys_save
	repo_keys_fill
	if {![winfo exists .repokeys]} return
	.repokeys.status configure -text "rio has forgotten the key for [dict get $row src]. The next scan of that repository asks you to confirm whatever key it publishes then, and installs nothing from it until you do."
}

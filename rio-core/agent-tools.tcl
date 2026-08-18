# rio-core — the agent's built-in tools: read (auto) + write (gated). D20, D26.
#
# The core owns tool *execution* (D20: security and cross-provider consistency
# live here, not in a provider plugin). This module is the registry + executor for
# the built-ins. Each tool wraps existing core ops (one implementation, the op's
# validation reused).
#
# Two kinds, split on safety:
#   read  (fs_list/fs_read/buffer_list/buffer_text) — inspection; auto-executed,
#         never mutates, rendered as transparency (slice 4).
#   write (propose_edit/propose_create) — mutation; NEVER auto-run. The loop
#         surfaces a diff and waits for the user's approval before apply_write
#         touches anything (slice 5). On approval the edit applies to the open
#         buffer (undoable) and, by default, is written to disk.
#
# Rails: path inputs are confined to the open project root (absolute / ../ escapes
# refused); read results are size-capped. The write surface reaches disk only
# through fs.write, only after approval — and an approved edit is RE-LOCATED at
# apply time (see apply_write): the editor stays live while a proposal awaits its
# decision, so coordinates computed at prepare time may be stale.

namespace eval rio::agent::tools {
	variable max_bytes 100000    ;# per-read cap; larger reads are truncated + noted

	# name -> {kind, op, description, schema}. kind is read|write. The Claude-facing
	# name uses underscores — the Messages API tool-name grammar forbids '.'.
	variable specs {}
}

proc rio::agent::tools::_def {name kind op description schema} {
	variable specs
	dict set specs $name [dict create kind $kind op $op description $description schema $schema]
}

rio::agent::tools::_def fs_list read fs.list \
	"List a directory in the open project. Returns each entry's name and type (file or dir). Omit path for the project root; pass a relative path to list a subdirectory." \
	{{"type":"object","properties":{"path":{"type":"string","description":"Directory path relative to the project root (omit for the root)."}}}}

rio::agent::tools::_def fs_read read fs.read \
	"Read a text file in the open project and return its contents. Use fs_list to discover files first." \
	{{"type":"object","properties":{"path":{"type":"string","description":"File path relative to the project root."}},"required":["path"]}}

rio::agent::tools::_def buffer_list read buffer.list \
	"List the buffers currently open in the editor, with their ids, names, paths, and line counts." \
	{{"type":"object","properties":{}}}

rio::agent::tools::_def buffer_text read buffer.text \
	"Return the current (possibly unsaved) text of an open buffer. Always pass a buffer id from buffer_list — there is no notion of an \"active\" buffer here." \
	{{"type":"object","properties":{"buffer":{"type":"string","description":"Buffer id from buffer_list."}},"required":["buffer"]}}

rio::agent::tools::_def propose_edit write "" \
	"Propose an edit to a project file: replace old_string with new_string. old_string must match EXACTLY ONCE in the file — include enough surrounding context to be unique. The user reviews a diff and approves or rejects before anything changes." \
	{{"type":"object","properties":{"path":{"type":"string","description":"File path relative to the project root."},"old_string":{"type":"string","description":"The exact text to replace (must occur exactly once)."},"new_string":{"type":"string","description":"The replacement text."}},"required":["path","old_string","new_string"]}}

rio::agent::tools::_def propose_create write "" \
	"Propose creating a new file in the project with the given content. Fails if the file already exists (use propose_edit instead). Parent folders are created. The user reviews and approves before the file is written." \
	{{"type":"object","properties":{"path":{"type":"string","description":"New file path relative to the project root."},"content":{"type":"string","description":"The file's contents."}},"required":["path","content"]}}

# The tool specs handed to a provider: {name, description, input_schema} per tool.
# input_schema is a JSON-string fragment the provider splices verbatim (D26).
proc rio::agent::tools::specs {} {
	variable specs
	set out {}
	dict for {name s} $specs {
		lappend out [dict create name $name \
			description [dict get $s description] \
			input_schema [dict get $s schema]]
	}
	return $out
}

# Is this a mutating tool (needs the approval gate)?
proc rio::agent::tools::is_write {name} {
	variable specs
	expr {[dict exists $specs $name] && [dict get $specs $name kind] eq "write"}
}

# Execute one READ tool call. Returns {ok <0|1>, content <text for Claude>, summary
# <short line for the chat>}. Never raises: a refusal or a failed op comes back as
# ok 0 with an explanatory content, which the loop relays to Claude as an is_error
# tool_result so the model can recover (D26 resilience).
proc rio::agent::tools::run {name input} {
	variable specs
	if {![dict exists $specs $name]} {
		return [_err "unknown tool: $name" "unknown tool"]
	}
	set op [dict get $specs $name op]
	if {[dict exists $input path]} {
		set guard [_confine [dict get $input path]]
		if {[dict get $guard ok] == 0} { return $guard }
	}
	set out [rio::core::call $op $input]
	set resp [dict get $out response]
	if {![dict get $resp ok]} {
		set e [dict get $resp error]
		return [_err "[dict get $e code]: [dict get $e message]" "error: [dict get $e code]"]
	}
	return [_format $name [dict get $resp result]]
}

# --- write: prepare (build a reviewable plan + diff) -------------------------
# Returns {ok 1, name, path, diff, plan} for the loop to surface and later apply,
# or {ok 0, content, summary} when the proposal can't be formed (so the model gets
# an actionable tool_result without anything being touched).
proc rio::agent::tools::prepare_write {name input} {
	if {![dict exists $input path]} { return [_err "missing path" "error: missing path"] }
	set guard [_confine [dict get $input path]]
	if {[dict get $guard ok] == 0} { return $guard }
	set abs [rio::project::resolve [dict get $input path]]
	set rel [_rel $abs]
	switch -- $name {
		propose_edit {
			foreach k {old_string new_string} {
				if {![dict exists $input $k]} { return [_err "propose_edit requires $k" "error: missing $k"] }
			}
			set old [dict get $input old_string]
			set new [dict get $input new_string]
			set cur [_current_text $abs]
			if {[dict get $cur ok] == 0} {
				return [_err "file not found: $rel — use propose_create for a new file" "error: no such file"]
			}
			set text [dict get $cur text]
			set loc [_locate $text $old]
			if {[dict get $loc ok] == 0} {
				set c [dict get $loc count]
				if {$c == 0} { return [_err "old_string not found in $rel" "error: not found"] }
				return [_err "old_string is not unique in $rel ($c matches) — add surrounding context" "error: $c matches"]
			}
			set newfull [string map [list $old $new] $text]
			# The plan carries old/new, NOT the located coordinates: apply_write
			# re-locates the match when the approval lands, so a buffer that moved
			# underneath the pending proposal can't be edited at a stale position.
			return [dict create ok 1 name $name path $rel diff [_difftext $old $new] \
				original $text proposed $newfull \
				plan [dict create kind edit abs $abs old $old new $new]]
		}
		propose_create {
			if {![dict exists $input content]} { return [_err "propose_create requires content" "error: missing content"] }
			if {[file exists $abs]} { return [_err "$rel already exists — use propose_edit" "error: exists"] }
			set content [dict get $input content]
			return [dict create ok 1 name $name path $rel diff [_difftext "" $content] \
				original "" proposed $content \
				plan [dict create kind create abs $abs content $content]]
		}
	}
	return [_err "unknown write tool: $name" "unknown tool"]
}

# --- write: apply (after approval) -------------------------------------------
# Returns {ok, content, summary, ?events?}. The loop forwards `events` on its emit so
# frontends update: buffer.changed for an open-buffer edit (the editor view repaints),
# fs.changed for a create or closed-file write (the file tree repaints, D47). Edits to
# an open buffer go through buffer.replace (undoable) and, when the disk flag is on,
# file.save; edits to a closed file and all creates are written straight to disk via
# fs.write, which is what emits the fs.changed the create/closed-edit paths forward.
#
# The ground truth is RE-RESOLVED here, not reused from prepare_write: the editor
# stays live while a proposal awaits its decision (the turn's coroutine is suspended
# at the approval gate), so the text — and even whether the file is open in a buffer
# — may have changed since the diff was built. An edit re-locates old_string under
# the same unique-match contract the user reviewed and refuses if it no longer
# holds; a create refuses if the file has appeared. Never apply at a stale position.
proc rio::agent::tools::apply_write {plan} {
	set abs  [dict get $plan abs]
	set rel  [_rel $abs]
	set disk [rio::agent::writes_disk]
	if {[dict get $plan kind] eq "create"} {
		if {[file exists $abs]} {
			return [_err "$rel was created while the proposal awaited approval — use propose_edit" "error: exists"]
		}
		set out [rio::core::call fs.write [dict create path $abs text [dict get $plan content]]]
		if {![_ok $out msg]} {
			return [_err "couldn't create $rel: $msg" "error: write failed"]
		}
		# Forward fs.write's fs.changed so the GUI file tree shows the new file (D47).
		return [dict create ok 1 content "created $rel" summary "created $rel" \
			events [dict get $out events]]
	}
	# edit: locate the match afresh in the file's CURRENT text
	set cur [_current_text $abs]
	if {[dict get $cur ok] == 0} {
		return [_err "$rel disappeared while the edit awaited approval" "error: no such file"]
	}
	set old  [dict get $plan old]
	set new  [dict get $plan new]
	set text [dict get $cur text]
	set loc  [_locate $text $old]
	if {[dict get $loc ok] == 0} {
		return [_err "$rel changed while the edit awaited approval — the text to replace no longer matches; read it again and re-propose" \
			"error: changed since proposal"]
	}
	set bufid [dict get $cur bufid]
	if {$bufid ne ""} {
		set out [rio::core::call buffer.replace [dict create buffer $bufid \
			start [dict get $loc start] end [dict get $loc end] text $new]]
		if {![dict get [dict get $out response] ok]} {
			return [_err "couldn't apply the edit to $rel" "error: edit failed"]
		}
		set events [dict get $out events]
		if {$disk && ![_ok [rio::core::call file.save [dict create buffer $bufid]] msg]} {
			return [dict create ok 0 content "applied to the buffer but saving $rel failed: $msg" \
				summary "error: save failed" events $events]
		}
		return [dict create ok 1 content "edited $rel" \
			summary "edited $rel ([expr {$disk ? {buffer+disk} : {buffer}}])" events $events]
	}
	# closed file: write straight to disk (stage-only has no buffer to land in)
	set out [rio::core::call fs.write [dict create path $abs text [string map [list $old $new] $text]]]
	if {![_ok $out msg]} {
		return [_err "couldn't write $rel: $msg" "error: write failed"]
	}
	return [dict create ok 1 content "edited $rel" summary "edited $rel (disk)" \
		events [dict get $out events]]
}

# --- helpers -----------------------------------------------------------------

# Check a path input against the project root. Returns ok=1 to proceed, or an
# ok=0 _err naming the real reason (no project open vs. escaping the root).
proc rio::agent::tools::_confine {path} {
	if {[catch {file normalize [rio::project::resolve ""]} rootn]} {
		return [_err "No project is open — open a folder first." "no project open"]
	}
	set abs [rio::project::resolve $path]
	if {$abs ne $rootn && [string first "$rootn/" "$abs/"] != 0} {
		return [_err "path is outside the open project: $path" "refused: outside project"]
	}
	return [dict create ok 1]
}

# A file's current text + the open buffer id backing it (or "" if not open). Reads
# the live buffer when open (so an edit sees unsaved changes), else from disk.
proc rio::agent::tools::_current_text {abs} {
	foreach b [rio::doc::inventory] {
		if {[dict get $b path] eq $abs} {
			return [dict create ok 1 text [rio::doc::text [dict get $b buffer]] bufid [dict get $b buffer]]
		}
	}
	if {![file isfile $abs]} { return [dict create ok 0] }
	return [dict create ok 1 text [dict get [rio::fs::read $abs] text] bufid ""]
}

# Locate `needle` in `text`. Returns {ok 1 start end} (line.col, the Tk index form
# buffer.replace wants) only when the match is UNIQUE; otherwise {ok 0 count}.
proc rio::agent::tools::_locate {text needle} {
	set count 0 ; set idx 0 ; set first -1
	while {[set p [string first $needle $text $idx]] >= 0} {
		if {$first < 0} { set first $p }
		incr count
		set idx [expr {$p + 1}]
	}
	if {$count != 1} { return [dict create ok 0 count $count] }
	return [dict create ok 1 \
		start [_linecol $text $first] \
		end   [_linecol $text [expr {$first + [string length $needle]}]]]
}

# A character offset -> a "line.col" index (1-based line, 0-based col).
proc rio::agent::tools::_linecol {text offset} {
	set pre [string range $text 0 [expr {$offset - 1}]]
	return "[expr {[regexp -all "\n" $pre] + 1}].[expr {$offset - ([string last "\n" $pre] + 1)}]"
}

# A path relative to the project root, for display.
proc rio::agent::tools::_rel {abs} {
	set root [file normalize [rio::project::resolve ""]]
	if {[string first "$root/" "$abs/"] == 0} {
		return [string range $abs [string length "$root/"] end]
	}
	return $abs
}

# A minimal review diff: removed lines as "- …", added as "+ …".
proc rio::agent::tools::_difftext {old new} {
	set out {}
	if {$old ne ""} { foreach l [split $old "\n"] { lappend out "- $l" } }
	foreach l [split $new "\n"] { lappend out "+ $l" }
	return [join $out "\n"]
}

# Was a core::call ok? On failure binds msgVar to its error message.
proc rio::agent::tools::_ok {out msgVar} {
	upvar 1 $msgVar msg
	set resp [dict get $out response]
	if {[dict get $resp ok]} { return 1 }
	set msg [dict get $resp error message]
	return 0
}

# Shape a READ op result into {ok, content, summary}, applying the size cap.
proc rio::agent::tools::_format {name result} {
	switch -- $name {
		fs_list {
			set lines {}
			foreach e [dict get $result entries] {
				set n [dict get $e name]
				lappend lines [expr {[dict get $e type] eq "dir" ? "$n/" : $n}]
			}
			return [_cap [join $lines "\n"] "[llength $lines] entries in [dict get $result path]"]
		}
		fs_read {
			return [_cap [dict get $result text] \
				"[dict get $result linecount] lines, [dict get $result encoding]"]
		}
		buffer_list {
			set lines {}
			foreach b [dict get $result buffers] {
				lappend lines "[dict get $b buffer]\t[dict get $b name]\t[dict get $b path]\t[dict get $b linecount]L"
			}
			return [_cap [join $lines "\n"] "[llength $lines] buffers"]
		}
		buffer_text {
			set t [dict get $result text]
			return [_cap $t "[string length $t] chars"]
		}
	}
	return [_cap $result ok]
}

proc rio::agent::tools::_cap {body summary} {
	variable max_bytes
	if {[string length $body] > $max_bytes} {
		set body "[string range $body 0 [expr {$max_bytes - 1}]]\n…(truncated at $max_bytes bytes)"
		append summary " (truncated)"
	}
	return [dict create ok 1 content $body summary $summary]
}

proc rio::agent::tools::_err {content summary} {
	return [dict create ok 0 content $content summary $summary]
}

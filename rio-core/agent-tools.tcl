# rio-core — the agent's built-in tools: read (auto) + write (gated). D20, D26.
#
# The core owns tool *execution* (D20: security and cross-provider consistency
# live here, not in a provider plugin). This module is the registry + executor for
# the built-ins. Each tool wraps existing core ops (one implementation, the op's
# validation reused).
#
# Kinds, split on safety:
#   read  (fs_list/fs_read/buffer_list/buffer_text) — inspection; auto-executed,
#         never mutates, rendered as transparency (slice 4).
#   write (propose_edit/propose_create, and replace_selection in a turn scoped to a
#         selection, D113) — mutation; NEVER auto-run. The loop
#         surfaces a diff and waits for the user's approval before apply_write
#         touches anything (slice 5). On approval the edit applies to the open
#         buffer (undoable) and, by default, is written to disk.
#   exec  (run_command) — an argv the user always confirms (D83).
#   plan  (present_plan) — the work described before it is done (D101): gated like a
#         write, but what it changes is the mode, not the project.
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

	# Tools that exist only inside a selection-scoped turn (D113).
	variable scoped_only {}
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

# The selection tool (D113): offered ONLY in a turn the user scoped to a selection, and
# in such a turn it is the only tool that changes anything. It names no path and no
# match — the core already holds the range — so the model can't aim it anywhere else.
rio::agent::tools::_def replace_selection write "" \
	"Replace the text the user selected (quoted in their message) with new text. This is the only way to change anything in this request, and it changes exactly the selection — nothing before or after it, no other buffer or file. Pass the whole replacement for the selected text, not a fragment of it. The user reviews a diff and approves or rejects before anything changes. Calling it again replaces what the previous call wrote." \
	{{"type":"object","properties":{"text":{"type":"string","description":"The complete replacement for the selected text."}},"required":["text"]}}
lappend rio::agent::tools::scoped_only replace_selection

rio::agent::tools::_def run_command exec "" \
	"Run a command in the open project and return its exit code, stdout, and stderr — for tests, a linter, a build, git, and the like. `command` is an ARGUMENT VECTOR, not a shell line: pass the program and each argument as separate array elements (e.g. \[\"pytest\",\"-q\",\"tests/\"\]). There is NO shell, so pipes, redirects, globs, quotes, ~, environment-variable expansion and `&&`/`;` do NOT work — chain steps by calling the tool again. The user reviews the exact command and approves or rejects before it runs; a run always waits for the human. A non-zero exit is a normal result (its code is data). cwd is confined to the project; the command is killed if it exceeds its timeout." \
	{{"type":"object","properties":{"command":{"type":"array","items":{"type":"string"},"description":"The command as an argument vector: the program followed by each argument as a separate string. Not a shell string."},"cwd":{"type":"string","description":"Working directory relative to the project root (omit for the root). Must stay within the project."},"timeout":{"type":"integer","description":"Seconds before the command is killed (default 120, max 600)."}},"required":["command"]}}

rio::agent::tools::_def present_plan plan "" \
	"Present your plan for the work, for the user to read and approve BEFORE anything changes. Use this whenever the user ASKS for a plan (\"plan this\", \"what would you do\", \"show me the plan first\"), and on your own judgement before a large, ambiguous or hard-to-reverse change — not for a small, obvious fix. Investigate first with the read tools, then call this ONCE with the whole plan. `plan` is Markdown — headings, lists, tables, fenced code — and the user reads it RENDERED, not as source, so write it for a person: what you understood the task to be, what you will change (file by file), and how it will be verified. Say what you are deliberately NOT doing. The user approves or rejects; on approval you carry the plan out, one reviewed edit at a time." \
	{{"type":"object","properties":{"title":{"type":"string","description":"A short name for the plan — one line, no Markdown."},"plan":{"type":"string","description":"The plan itself, as Markdown."}},"required":["title","plan"]}}

# The tool specs handed to a provider: {name, description, input_schema} per tool.
# input_schema is a JSON-string fragment the provider splices verbatim (D26).
#
# The set depends on the agent's MODE (D101): in `plan` mode the model gets the reads
# plus present_plan and NOTHING that changes anything — the restriction is real, not a
# request in the prompt, and it is provider-agnostic because the core composes this list
# for every provider.
#
# present_plan is offered in EVERY mode (D103). D101 withheld it outside plan mode, on the
# theory that a plan is what plan mode is for; the first live test showed what that costs —
# asked in plain words for a plan, the model had no plan tool to reach for and wrote a text
# file instead. Planning is a thing the user asks for, not a mode they must remember to
# enter first. Plan mode still has all its teeth: it is the mode that withholds every
# changing tool, which is a different guarantee from being able to present a plan.
#
# A turn `scoped` to a selection (D113) narrows it the same way, and for the same reason
# — the restriction is real, not a request in the prompt: every write and exec tool goes
# except replace_selection, which in turn exists in no other turn. Reads stay, for
# context. The two narrowings compose: scoped plan mode is reads + present_plan.
proc rio::agent::tools::specs {{mode build} {scoped 0}} {
	variable specs
	variable scoped_only
	set out {}
	dict for {name s} $specs {
		set kind [dict get $s kind]
		if {$mode eq "plan" && $kind ni {read plan}} continue
		if {$scoped} {
			if {$kind in {write exec} && $name ni $scoped_only} continue
		} elseif {$name in $scoped_only} continue
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

# A tool's kind (read|write|exec|plan), or "" if unknown.
proc rio::agent::tools::kind_of {name} {
	variable specs
	if {[dict exists $specs $name]} { return [dict get $specs $name kind] }
	return ""
}

# Does this tool go through the approval gate? Write (edit/create), exec
# (run_command) and plan (present_plan) all do; only reads auto-run.
proc rio::agent::tools::is_gated {name} {
	set k [kind_of $name]
	expr {$k in {write exec plan}}
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
proc rio::agent::tools::prepare_write {name input {scope {}}} {
	if {$name eq "replace_selection"} { return [_prepare_selection $input $scope] }
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
	if {[dict get $plan kind] eq "replace"} { return [_apply_selection $plan] }
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

# --- write: the selection (D113) ----------------------------------------------
# replace_selection edits the range agent.send was scoped to, in the open buffer,
# never a path. It keeps propose_edit's two promises: nothing applies at a stale
# position, and what applies is what the user reviewed.

# A buffer as the user knows it: its path (relative when inside the project), or its
# name when it has none — an untitled buffer can be scoped too.
proc rio::agent::tools::bufname {id} {
	set meta [rio::doc::meta $id]
	if {[dict exists $meta path] && [dict get $meta path] ne ""} {
		set p [dict get $meta path]
		if {![catch {_rel $p} rel]} { return $rel }
		return $p
	}
	foreach b [rio::doc::inventory] {
		if {[dict get $b buffer] eq $id} { return [dict get $b name] }
	}
	return $id
}

# Where the selection is NOW: {ok 1 start end}, or {ok 0}. Its own range if that still
# holds the text; else the text's one occurrence in the buffer (an edit above it moved
# it); else nowhere — changed, or no longer unique, and the caller refuses.
proc rio::agent::tools::_anchor {id start end old} {
	if {![catch {rio::doc::range_text $id $start $end} got] && $got eq $old} {
		return [dict create ok 1 start $start end $end]
	}
	set loc [_locate [rio::doc::text $id] $old]
	if {[dict get $loc ok]} {
		return [dict create ok 1 start [dict get $loc start] end [dict get $loc end]]
	}
	return [dict create ok 0]
}

proc rio::agent::tools::_prepare_selection {input scope} {
	if {![llength $scope]} {
		return [_err "replace_selection works only on a selection the user scoped the request to — there is none in this turn" "error: no selection"]
	}
	if {![dict exists $input text]} { return [_err "replace_selection requires text" "error: missing text"] }
	set id  [dict get $scope buffer]
	set old [dict get $scope original]
	if {![rio::doc::exists $id]} {
		return [_err "the buffer holding the selection was closed" "error: buffer closed"]
	}
	set at [_anchor $id [dict get $scope start] [dict get $scope end] $old]
	if {![dict get $at ok]} {
		return [_err "the selected text was changed in the editor — ask the user to select it again" \
			"error: selection changed"]
	}
	set new [dict get $input text]
	set proposed [join [lindex [rio::doc::_splice [rio::doc::lines $id] \
		[dict get $at start] [dict get $at end] $new] 0] "\n"]
	return [dict create ok 1 name replace_selection path [bufname $id] \
		diff [_difftext $old $new] original [rio::doc::text $id] proposed $proposed \
		plan [dict create kind replace buffer $id \
			start [dict get $at start] end [dict get $at end] old $old new $new]]
}

# Apply after approval: anchor afresh (the editor stayed live), replace through
# buffer.replace (one undo step), save under the same rule as any agent edit — a buffer
# with no file is never saved. Returns the moved scope for the turn to keep.
proc rio::agent::tools::_apply_selection {plan} {
	set id  [dict get $plan buffer]
	set old [dict get $plan old]
	set new [dict get $plan new]
	if {![rio::doc::exists $id]} {
		return [_err "the buffer holding the selection was closed while the edit awaited approval" "error: buffer closed"]
	}
	set name [bufname $id]
	set at [_anchor $id [dict get $plan start] [dict get $plan end] $old]
	if {![dict get $at ok]} {
		return [_err "the selection in $name changed while the edit awaited approval — nothing was replaced" \
			"error: changed since proposal"]
	}
	set start [dict get $at start]
	set out [rio::core::call buffer.replace [dict create buffer $id \
		start $start end [dict get $at end] text $new coalesce 0]]
	if {![_ok $out msg]} {
		return [_err "couldn't replace the selection in $name: $msg" "error: edit failed"]
	}
	set events [dict get $out events]
	set scope [dict create buffer $id start $start end [rio::doc::_advance $start $new] original $new]
	set meta [rio::doc::meta $id]
	set saved [expr {[rio::agent::writes_disk] && [dict exists $meta path] && [dict get $meta path] ne ""}]
	if {$saved && ![_ok [rio::core::call file.save [dict create buffer $id]] msg]} {
		return [dict create ok 0 content "replaced the selection in the buffer but saving $name failed: $msg" \
			summary "error: save failed" events $events scope $scope]
	}
	return [dict create ok 1 content "replaced the selection in $name" \
		summary "replaced the selection in $name ([expr {$saved ? {buffer+disk} : {buffer}}])" \
		events $events scope $scope]
}

# --- plan: prepare (shape it, and keep a copy) -------------------------------
# The present_plan tool (D101). Returns {ok 1, name, title, markdown, path} for the loop
# to surface (agent.propose, kind plan) and for the user to approve. Nothing here touches
# the project's own files: the only write is the plan's own copy under `.rio/plans/`, so
# a plan is a record even when it is rejected — and `path` is "" when there is no project
# to keep it in (D72), which is not an error, only a plan that leaves no trace.
proc rio::agent::tools::prepare_plan {input} {
	foreach k {title plan} {
		if {![dict exists $input $k] || [string trim [dict get $input $k]] eq ""} {
			return [_err "present_plan requires $k" "error: missing $k"]
		}
	}
	set title [string trim [dict get $input title]]
	set md [_plan_markdown $title [string trim [dict get $input plan]]]
	return [dict create ok 1 name present_plan title $title markdown $md \
		path [_plan_save $title $md]]
}

# The plan as one Markdown document: its title as the opening heading, unless the model
# already wrote one (then its own is kept — two titles read worse than either).
proc rio::agent::tools::_plan_markdown {title body} {
	foreach line [split $body "\n"] {
		if {[string trim $line] eq ""} continue
		if {[string index [string trimleft $line] 0] eq "#"} { return $body }
		break
	}
	return "# $title\n\n$body"
}

# Write the plan under the open project's `.rio/plans/` and return its project-relative
# path, or "" (no project, or the write failed — a plan that cannot be filed is still a
# plan worth reading). Timestamped and slugged so the directory reads as a history; a
# same-second collision takes the next free suffix rather than overwriting.
proc rio::agent::tools::_plan_save {title md} {
	set root [rio::project::root]
	if {$root eq ""} { return "" }
	set stamp [clock format [clock seconds] -format %Y%m%d-%H%M%S]
	set base "$stamp-[_slug $title]"
	set rel [file join .rio plans "$base.md"]
	for {set n 2} {[file exists [file join $root $rel]]} {incr n} {
		set rel [file join .rio plans "$base-$n.md"]
	}
	set abs [file join $root $rel]
	if {[catch {
		file mkdir [file dirname $abs]
		set fh [open $abs w]
		fconfigure $fh -encoding utf-8
		puts $fh $md
		close $fh
	}]} { return "" }
	return $rel
}

# Read a filed plan back, as the user has it NOW: the live buffer when the file is open
# (so a plan edited and not yet saved still counts — nobody should have to remember to
# save before approving), else the disk copy. Returns "" for no path, no project, or an
# unreadable file; the caller falls back to the plan as presented (D102).
proc rio::agent::tools::read_plan {path} {
	if {$path eq ""} { return "" }
	if {[catch {rio::project::resolve $path} abs]} { return "" }
	set cur [_current_text $abs]
	if {![dict get $cur ok]} { return "" }
	return [dict get $cur text]
}

# A title as a filename fragment: lowercase, runs of anything else collapsed to one
# dash, trimmed and length-capped. Never empty — a title of pure punctuation still
# needs a name.
proc rio::agent::tools::_slug {s} {
	set out [string trim [regsub -all -- {-+} [regsub -all {[^a-z0-9]+} [string tolower $s] -] -] -]
	if {$out eq ""} { return plan }
	return [string trim [string range $out 0 47] -]
}

# --- exec: prepare (validate + build a reviewable command) -------------------
# The run_command tool (D83). Returns {ok 1, name, command, cwd, timeout, display}
# for the loop to surface (agent.propose, kind command) and — only after the user
# approves — run asynchronously via rio::exec::start. Like a write it NEVER
# auto-runs; unlike a write the approval is not skippable (running arbitrary argv
# is the most dangerous surface, so a human always sees the exact command first).
# On a bad request returns an ok 0 _err the model can act on.
proc rio::agent::tools::prepare_exec {input} {
	if {![dict exists $input command]} {
		return [_err "run_command requires command (an argument vector)" "error: missing command"]
	}
	set argv [dict get $input command]
	if {[llength $argv] == 0} { return [_err "command is empty" "error: empty command"] }
	# No shell: refuse any element Tcl's exec would interpret as a redirection or
	# pipe rather than pass to the program. This closes the residual exec
	# redirection-token surface (exec.tcl) on the agent path — a model can't smuggle
	# a `> /etc/passwd` past the human by hiding it in an argv element.
	foreach a $argv {
		if {[_is_redirection $a]} {
			return [_err "the argument \"$a\" looks like a shell redirection or pipe — run_command takes a literal argument vector, not a shell line (no <, >, |, &). Pass the program and each argument separately." \
				"refused: shell token"]
		}
	}
	# cwd: default to the project root; a given cwd is confined to the project.
	if {[dict exists $input cwd] && [dict get $input cwd] ne ""} {
		set guard [_confine [dict get $input cwd]]
		if {[dict get $guard ok] == 0} { return $guard }
		set cwd [rio::project::resolve [dict get $input cwd]]
		if {![file isdirectory $cwd]} {
			return [_err "cwd is not a directory: [dict get $input cwd]" "error: no such dir"]
		}
	} else {
		if {[catch {rio::project::resolve ""} cwd]} {
			return [_err "No project is open — open a folder first." "no project open"]
		}
	}
	set timeout [_clamp_timeout [expr {[dict exists $input timeout] ? [dict get $input timeout] : 0}]]
	# cwd is absolute (for the run); cwddisp is the project-relative dir for the
	# review surface ("" = the project root), so a frontend needn't know the root.
	return [dict create ok 1 name run_command command $argv cwd $cwd \
		cwddisp [_rel $cwd] timeout $timeout display [_cmd_display $argv]]
}

# Shape an async exec result ({exitcode, stdout, stderr, timedout, ?error}) into the
# {ok, content, summary} the loop turns into a tool_result. A non-zero exit is a
# SUCCESSFUL run (ok 1) — the exit code is data the model reads; only a launch
# failure or a timeout is ok 0 (is_error), so the model knows the command didn't
# actually complete.
proc rio::agent::tools::format_exec {argv result} {
	set disp [_cmd_display $argv]
	if {[dict exists $result error]} {
		return [_err "couldn't run $disp: [dict get $result error]" "error: couldn't run"]
	}
	if {[dict get $result timedout]} {
		return [dict create ok 0 \
			content "The command was killed after exceeding its timeout:\n\$ $disp\n[_exec_streams $result]" \
			summary "timed out: $disp"]
	}
	set ec [dict get $result exitcode]
	return [_cap "exit code: $ec\n[_exec_streams $result]" "ran $disp -> exit $ec"]
}

# Would Tcl's exec read this argument as a redirection or pipe (rather than pass it
# to the program)? True for a leading <, >, >>, 2>, <<, <@, >@, >&, a leading |, or
# a lone &. Only leading operators matter — exec treats a whole argument as
# redirection only when it starts with the operator (an arg like "a>b" is literal).
proc rio::agent::tools::_is_redirection {a} {
	if {$a eq "&"} { return 1 }
	return [regexp {^([0-9]*[<>]|\|)} $a]
}

# Clamp a requested timeout (seconds) to [1,600]; a missing/invalid/<=0 value
# becomes the 120 s default. There is no "unlimited" — every command is bounded,
# since there is no per-command cancel yet.
proc rio::agent::tools::_clamp_timeout {v} {
	if {![string is integer -strict $v] || $v <= 0} { return 120 }
	if {$v > 600} { return 600 }
	return $v
}

# A shell-style rendering of an argv, for the human's review line and the tool_result
# echo. Display only — nothing is ever run through a shell; single-quote any element
# with whitespace or shell-special characters so the review reads unambiguously.
proc rio::agent::tools::_cmd_display {argv} {
	set out {}
	foreach a $argv {
		if {$a eq "" || [regexp {[^A-Za-z0-9_./:=@%+-]} $a]} {
			lappend out "'[string map {' '\\''} $a]'"
		} else {
			lappend out $a
		}
	}
	return [join $out " "]
}

# The stdout/stderr sections of an exec result, trailing blank lines trimmed.
proc rio::agent::tools::_exec_streams {result} {
	set out [string trimright [dict get $result stdout] "\n"]
	set err [string trimright [dict get $result stderr] "\n"]
	return "--- stdout ---\n$out\n--- stderr ---\n$err"
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

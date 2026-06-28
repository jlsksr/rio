# rio-core — the agent's built-in read-only tools (AGENTS.md D20, D26 slice 4).
#
# The core owns tool *execution* (D20: security and cross-provider consistency
# live here, not in a provider plugin). This module is the registry + executor for
# the read-only built-ins the agent may run WITHOUT user approval — listing and
# reading project files, and reading open buffers. Each tool wraps an existing
# core op (one implementation, the op's validation reused) and is read-only by
# construction: only read ops are registered, so a provider can never reach a
# write through this surface. Writes / run-commands and their approval gate are a
# later slice (O4).
#
# Two rails make this "the safe half": path inputs are confined to the open
# project root (an absolute or ../-escaping path is refused, not read), and a
# result is capped in size so one read can't blow up the token budget.

namespace eval rio::agent::tools {
	variable max_bytes 100000    ;# per-read cap; larger reads are truncated + noted

	# name -> {description, schema (JSON input_schema fragment), op}. The Claude-facing
	# name uses underscores — the Messages API tool-name grammar forbids '.'.
	variable specs {}
}

proc rio::agent::tools::_def {name op description schema} {
	variable specs
	dict set specs $name [dict create description $description schema $schema op $op]
}

rio::agent::tools::_def fs_list fs.list \
	"List a directory in the open project. Returns each entry's name and type (file or dir). Omit path for the project root; pass a relative path to list a subdirectory." \
	{{"type":"object","properties":{"path":{"type":"string","description":"Directory path relative to the project root (omit for the root)."}}}}

rio::agent::tools::_def fs_read fs.read \
	"Read a text file in the open project and return its contents. Use fs_list to discover files first." \
	{{"type":"object","properties":{"path":{"type":"string","description":"File path relative to the project root."}},"required":["path"]}}

rio::agent::tools::_def buffer_list buffer.list \
	"List the buffers currently open in the editor, with their ids, names, paths, and line counts." \
	{{"type":"object","properties":{}}}

rio::agent::tools::_def buffer_text buffer.text \
	"Return the current (possibly unsaved) text of an open buffer. Pass a buffer id from buffer_list; omit it for the active buffer." \
	{{"type":"object","properties":{"buffer":{"type":"string","description":"Buffer id from buffer_list (omit for the active buffer)."}}}}

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

# Execute one tool call. Returns {ok <0|1>, content <text for Claude>, summary
# <short line for the chat>}. Never raises: a refusal or a failed op comes back as
# ok 0 with an explanatory content, which the loop relays to Claude as an is_error
# tool_result so the model can recover (D26 resilience).
proc rio::agent::tools::run {name input} {
	variable specs
	if {![dict exists $specs $name]} {
		return [_err "unknown tool: $name" "unknown tool"]
	}
	set op [dict get $specs $name op]
	# Confine path inputs to the project root — the read-only "safe half" must not
	# become arbitrary host-filesystem read access (D26 containment).
	if {[dict exists $input path]} {
		if {[catch {_confine [dict get $input path]} msg]} {
			return [_err $msg "refused: outside project"]
		}
	}
	set out [rio::core::call $op $input]
	set resp [dict get $out response]
	if {![dict get $resp ok]} {
		set e [dict get $resp error]
		return [_err "[dict get $e code]: [dict get $e message]" "error: [dict get $e code]"]
	}
	return [_format $name [dict get $resp result]]
}

# Verify a path resolves inside the open project root. Raises when it escapes (an
# absolute path elsewhere, or ../ traversal) so run() can turn it into a refusal.
proc rio::agent::tools::_confine {path} {
	set abs   [rio::project::resolve $path]
	set rootn [file normalize [rio::project::resolve ""]]   ;# raises if no project open
	if {$abs ne $rootn && [string first "$rootn/" "$abs/"] != 0} {
		error "path is outside the open project: $path"
	}
	return $abs
}

# Shape an op result into {ok, content, summary}, applying the size cap.
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

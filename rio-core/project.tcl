# rio-core — the project / workspace root (AGENTS.md D11, the project.* namespace).
#
# rio is "the editor with a project open": one canonical root folder the core
# holds, which anchors everything that is otherwise relative — git operations
# (the cwd for git.*), directory listing for the file tree (fs.list), and the
# per-project `.rio/` config dir. Before this, git.* leaned on the core process's
# own working directory; the root makes "the project" an explicit, queryable
# fact instead of an accident of how rio was launched.
#
# Single-root by design (a workspace is one open folder, matching one git repo);
# multi-root can grow later without changing this seam. Pure state — no Tk, no
# protocol — so it tests headless.

namespace eval rio::project {
	variable root ""   ;# absolute path of the open project, or "" if none
}

# Open `path` as the project root: it must be an existing directory. Returns the
# normalized absolute root. Replacing one root with another is allowed (the
# caller decides what that means for open buffers; the model just records it).
proc rio::project::open {path} {
	variable root
	if {$path eq ""} {
		rio::error::raise bad_request "project.open requires a path"
	}
	set abs [file normalize $path]
	if {![file isdirectory $abs]} {
		rio::error::raise io_error "not a directory: $path"
	}
	set root $abs
	return $root
}

# The current root, or "" if no project is open.
proc rio::project::root {} {
	variable root
	return $root
}

# Resolve `path` against the project root the way a frontend means it: an empty
# path is the root itself; an absolute path is taken as-is; a relative path is
# joined onto the root. Raises if there is nothing to resolve against (no path
# and no open project) — callers that need a concrete directory use this.
proc rio::project::resolve {path} {
	variable root
	if {$path eq ""} {
		if {$root eq ""} {
			rio::error::raise bad_request "no path given and no project open"
		}
		return $root
	}
	if {[file pathtype $path] eq "absolute"} {
		return [file normalize $path]
	}
	if {$root eq ""} {
		rio::error::raise bad_request "relative path but no project open: $path"
	}
	return [file normalize [file join $root $path]]
}

# Forget the open project (its root becomes "").
proc rio::project::close {} {
	variable root
	set root ""
}

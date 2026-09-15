# rio-core — the error taxonomy (AGENTS.md D11, O2).
#
# An op signals failure by raising a Tcl error whose -errorcode carries a stable,
# machine-readable code: `rio::error::raise no_buffer "no such buffer: 7"`. The
# dispatcher turns that into the protocol's error reply — a flat object
# {code, message} (D11) — so a client can branch on `code` without parsing prose,
# while the human message stays for display and logging.
#
# The vocabulary is deliberately small (rio stays simple):
#   bad_request — the request itself is malformed (missing op, missing/bad params)
#   unknown_op  — no op of that name is registered
#   no_buffer   — the referenced buffer id does not exist
#   no_path     — a save needs a path and the buffer has none
#   bad_index   — a line.col index is out of range or malformed
#   io_error    — a file could not be read or written
#   untrusted_cert — an https server's certificate did not verify and no exception
#                 accepts it (D111); tls.inspect shows it, tls.accept accepts it
#   internal    — an unexpected failure (an uncaught Tcl error); a bug
#
# `internal` is the catch-all the dispatcher assigns to any error raised WITHOUT
# a rio code (a plain `error`, a Tcl runtime fault), so an overlooked failure
# still reaches the client as a clean reply instead of leaking a stack trace.

namespace eval rio::error {
	variable codes {bad_request unknown_op no_buffer no_path bad_index io_error untrusted_cert internal}
}

# Raise a failure carrying a taxonomy code. Called inside op handlers; the
# dispatcher reads the code back off the caught error's -errorcode.
proc rio::error::raise {code message} {
	return -code error -errorcode [list RIO $code] $message
}

# The taxonomy code carried by a caught error's options dict (the third word of
# `catch`), or `internal` for anything not raised through `raise`.
proc rio::error::code_of {opts} {
	if {[dict exists $opts -errorcode]} {
		set ec [dict get $opts -errorcode]
		if {[lindex $ec 0] eq "RIO"} { return [lindex $ec 1] }
	}
	return internal
}

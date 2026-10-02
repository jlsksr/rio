# rio-core — the error taxonomy (D11, O2).
#
# An op fails by raising a Tcl error with a code:
#
#   rio::error::raise no_buffer "no such buffer: 7"
#     -> {"id":…,"ok":false,"error":{"code":"no_buffer","message":"no such buffer: 7"}}
#
# A client branches on `code` and shows `message`.
#
#   bad_request    — the request is malformed (missing op, bad params)
#   unknown_op     — no op of that name is registered
#   no_buffer      — the buffer id does not exist
#   no_path        — a save needs a path and the buffer has none
#   bad_index      — a line.col index is out of range or malformed
#   io_error       — a file could not be read or written
#   untrusted_cert — an https certificate did not verify and no exception
#                    accepts it (D111); see tls.inspect, tls.accept
#   too_large      — the file is bigger than the op reads unasked (D125)
#   binary_file    — the file looks binary, not text (D125)
#   internal       — any error raised without a code: a bug
#
# The three before `internal` are questions more than failures: a frontend
# that knows the code offers the way past it. One that does not shows the
# message. So a new code breaks no client.

namespace eval rio::error {
	variable codes {bad_request unknown_op no_buffer no_path bad_index io_error untrusted_cert too_large binary_file internal}
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

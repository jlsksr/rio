# plugins/lib — shared JSON serialisation for LLM providers (D8/D26).
#
# What every provider needs to build a request body: a JSON string
# literal, and a JSON object from a flat dict. All output is pure ASCII.
# Pure string work: no Tk, no network.
#
# Several plugin loaders source this file; the guard defines it once.

if {[llength [info commands rio::llm::jstr]]} { return }

namespace eval rio::llm {}

# A JSON string literal. Escapes ", \ and control characters (RFC 8259),
# and \u-escapes everything non-ASCII: ASCII survives whatever encoding
# the HTTP layer applies. Above U+FFFF: a surrogate pair.
#   jstr "a\"b →"   ->   "a\"b →"
proc rio::llm::jstr {s} {
	set out ""
	foreach ch [split $s ""] {
		scan $ch %c code
		if {$ch eq "\""} {
			append out {\"}
		} elseif {$ch eq "\\"} {
			append out {\\}
		} elseif {$code < 0x20} {
			switch -- $code {
				8  { append out {\b} }
				9  { append out {\t} }
				10 { append out {\n} }
				12 { append out {\f} }
				13 { append out {\r} }
				default { append out [format {\u%04x} $code] }
			}
		} elseif {$code > 0xffff} {
			set c [expr {$code - 0x10000}]
			append out [format {\u%04x\u%04x} \
				[expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
		} elseif {$code > 0x7e} {
			append out [format {\u%04x} $code]
		} else {
			append out $ch
		}
	}
	return "\"$out\""
}

# \u-escape every non-ASCII character of a valid JSON document.
#
# Why: a provider puts the core's tool schemas into the body as they are;
# they are JSON already and may hold non-ASCII. Tcl's http writes the body
# to a binary channel, so U+2014 would go out as the byte 0x14: a raw
# control character, invalid JSON.
#
# Safe: in valid JSON, non-ASCII occurs only inside strings. Idempotent.
proc rio::llm::jascii {s} {
	set out ""
	foreach ch [split $s ""] {
		scan $ch %c code
		if {$code <= 0x7e} {
			append out $ch
		} elseif {$code > 0xffff} {
			set c [expr {$code - 0x10000}]
			append out [format {\u%04x\u%04x} \
				[expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
		} else {
			append out [format {\u%04x} $code]
		}
	}
	return $out
}

# A flat dict as a JSON object; every value becomes a string.
#   obj_json {path a.txt n 3}   ->   {"path":"a.txt","n":"3"}
proc rio::llm::obj_json {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[jstr $k]:[jstr $v]" }
	return "{[join $parts ,]}"
}

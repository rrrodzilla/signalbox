src/lib.rs:12 — panics when a segment has no `=` — empty input, missing separators, consecutive `;`, or a trailing `;` make `parts.next()` return `None` — malformed/empty segments must be handled without panicking; empty input should produce an empty vector.

src/lib.rs:10 — values containing additional `=` characters are truncated — `a=b=c` produces `("a", "b")` and silently discards `=c` — split each pair only at the first `=`, producing `("a", "b=c")`.

REQUEST_CHANGES
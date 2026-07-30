"""Safe diagnostic records for completed model invocations."""

from __future__ import annotations

from typing import Any


STDERR_LIMIT = 2000
TRUNCATION_MARKER = "... [truncated]"


def _text(value: Any) -> str:
    """Best-effort text conversion for values on an already-failing path."""
    if value is None:
        return ""
    try:
        return value if isinstance(value, str) else str(value)
    except Exception:
        return "<unprintable>"


def _command(command: Any) -> list[str]:
    """Return publishable argv, redacting Claude's prompt argument."""
    if command is None:
        return []
    try:
        values = list(command) if not isinstance(command, str) else [command]
    except Exception:
        values = [command]

    rendered = [_text(value) for value in values]
    try:
        if rendered and rendered[0] == "claude":
            prompt_flag = rendered.index("-p")
            prompt_index = prompt_flag + 1
            if prompt_index < len(rendered):
                rendered[prompt_index] = (
                    f"<redacted: {len(rendered[prompt_index])} chars>"
                )
    except Exception:
        # A malformed argv must not mask the invocation failure being reported.
        pass
    return rendered


def diagnostic(completed: Any, command: Any) -> dict[str, Any]:
    """Describe a failed invocation, or return an empty mapping on success.

    This helper is deliberately fail-open: provenance is observability, and
    constructing its diagnostic must never become a second failure.
    """
    try:
        returncode = getattr(completed, "returncode", None)
        if returncode == 0:
            return {}

        stderr = _text(getattr(completed, "stderr", None)).strip()
        if len(stderr) > STDERR_LIMIT:
            stderr = stderr[: STDERR_LIMIT - len(TRUNCATION_MARKER)] + TRUNCATION_MARKER

        return {
            "stderr": stderr,
            "exit_code": returncode,
            "command": _command(command),
        }
    except Exception:
        return {}


invocation_diagnostic = diagnostic

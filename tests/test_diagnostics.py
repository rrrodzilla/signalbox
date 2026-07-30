from types import SimpleNamespace

from signalbox.diagnostics import STDERR_LIMIT, diagnostic


def test_claude_prompt_is_redacted_but_flags_remain():
    prompt = '{"payload":{"issue_body":"a secret issue body"}}'
    command = [
        "claude",
        "-p",
        prompt,
        "--model",
        "sonnet",
        "--allowedTools",
        "Read",
    ]

    record = diagnostic(
        SimpleNamespace(returncode=17, stderr="model failed"), command
    )

    assert record == {
        "stderr": "model failed",
        "exit_code": 17,
        "command": [
            "claude",
            "-p",
            f"<redacted: {len(prompt)} chars>",
            "--model",
            "sonnet",
            "--allowedTools",
            "Read",
        ],
    }
    assert prompt not in repr(record)


def test_codex_argv_is_preserved_because_its_prompt_arrives_on_stdin():
    command = [
        "codex",
        "exec",
        "-C",
        "/tmp/worktree",
        "--sandbox",
        "workspace-write",
        "-",
    ]

    record = diagnostic(SimpleNamespace(returncode=9, stderr="nope"), command)

    assert record["command"] == command


def test_long_stderr_is_capped_and_visibly_marked():
    record = diagnostic(
        SimpleNamespace(returncode=1, stderr="x" * (STDERR_LIMIT + 50)),
        ["claude", "-p", "prompt"],
    )

    assert len(record["stderr"]) == STDERR_LIMIT
    assert record["stderr"].endswith("... [truncated]")


def test_success_has_no_diagnostic():
    assert (
        diagnostic(
            SimpleNamespace(returncode=0, stderr="warning"),
            ["claude", "-p", "prompt"],
        )
        == {}
    )


def test_odd_failure_inputs_do_not_raise():
    class Unprintable:
        def __str__(self):
            raise ValueError("cannot stringify")

    assert diagnostic(
        SimpleNamespace(returncode=None, stderr=None),
        [None, Unprintable()],
    ) == {
        "stderr": "",
        "exit_code": None,
        "command": ["", "<unprintable>"],
    }
    assert diagnostic(None, None) == {
        "stderr": "",
        "exit_code": None,
        "command": [],
    }

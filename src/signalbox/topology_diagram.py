"""Pure, deterministic README pictures resolved from ``emergent.toml``."""

from __future__ import annotations

from collections import defaultdict, deque
import textwrap
from typing import Any

GROUPS = ("sources", "handlers", "sinks")
REMEDIATION_ROUTER = "route-remediation-open"
ROOT_TOPIC = "run.requested"

# Agent and reaper subprocesses re-enter the engine out of band.  Once an
# acting sink has dispatched, any of these ingress handlers can be the next
# topology-visible node; treating them as graph edges is what keeps the whole
# lifecycle reachable rather than stopping the picture at shard.opened.
REENTRY_HANDLERS = (
    "route-run-requested",
    "route-file-written",
    "route-check-ran",
    "route-shard-submitted",
    "route-approval-granted",
    "route-model-invoked",
    "route-unknown-emission",
    "route-check-suite",
    "raise-reaped",
    "raise-pr-reaped",
)

HIDDEN_TOPICS: dict[str, str] = {
    "assess.failed": "primitive failure detail is summarized by run.halted",
    "branch.rebase-failed": "primitive failure detail is summarized by run.halted",
    "branch.rebase-invalid-verdict": "shown in the remediation detail block",
    "checks.silent": "shown in the remediation detail block",
    "checks.unknown-pr": "webhook validation detail is outside the lifecycle overview",
    "control.unknown-event": "control-plane validation is outside the lifecycle overview",
    "exec.exit": "raw source envelope",
    "exec.output": "raw source envelope",
    "gate.blocked": "shown in the remediation detail block",
    "gate.invalid-verdict": "shown in the remediation detail block",
    "http.request": "raw source envelope",
    "model.invoked": "cross-cutting provenance would obscure every model edge",
    "note.drafted": "intermediate documentation fan-out detail",
    "note.write-failed": "primitive failure detail is summarized by run.halted",
    "notes.plan-failed": "primitive failure detail is summarized by run.halted",
    "plan.audit-failed": "primitive failure detail is summarized by run.halted",
    "plan.draft-failed": "primitive failure detail is summarized by run.halted",
    "remediation.assessed": "expanded in the remediation detail block",
    "remediation.closed": "expanded in the remediation detail block",
    "remediation.failed": "expanded in the remediation detail block",
    "remediation.invalid-verdict": "expanded in the remediation detail block",
    "remediation.requested": "expanded in the remediation detail block",
    "review.failed": "primitive failure detail is summarized by run.halted",
    "review.invalid-verdict": "shown in the remediation detail block",
    "shard.abandoned": "timeout bookkeeping detail",
    "shard.escalated": "timeout bookkeeping detail",
    "shard.invalid-verdict": "review validation detail",
    "shard.silent": "timeout bookkeeping detail",
    "workspace.release-attempted": "post-completion housekeeping",
    "workspace.release-failed": "post-completion housekeeping",
    "workspace.released": "post-completion housekeeping",
}

ANNOTATIONS: dict[tuple[str, str], str] = {
    ("primitive", "draft-plan"): "opus; surveys the tree and reads the vault",
    ("primitive", "audit-plan"): "codex; adversarial",
    ("topic", "plan.rejected"): "attempt < 3",
}


class TopologyDiagramError(RuntimeError):
    """The resolved configuration cannot produce a truthful picture."""


class InvalidPrimitive(TopologyDiagramError):
    """A topology primitive has no usable name."""


class StaleProjection(TopologyDiagramError):
    """A written projection exemption no longer names resolved topology."""


class RemediationRouterMissing(TopologyDiagramError):
    """The remediation detail block has no configured fan-in router."""


def _primitives(config: dict[str, Any]) -> list[dict[str, Any]]:
    return [primitive for group in GROUPS for primitive in config.get(group, [])]


def resolve_topology(config: dict[str, Any]) -> dict[str, Any]:
    """Resolve names, topics, declaration order, and directed edges."""
    primitives = _primitives(config)
    names: list[str] = []
    publishers: defaultdict[str, list[str]] = defaultdict(list)
    subscribers: defaultdict[str, list[str]] = defaultdict(list)
    topic_order: dict[str, int] = {}
    for primitive in primitives:
        raw_name = primitive.get("name")
        if not isinstance(raw_name, str) or not raw_name.strip():
            raise InvalidPrimitive("topology primitive has no non-empty name")
        name = raw_name
        names.append(name)
        for topic in primitive.get("publishes", []):
            value = str(topic)
            topic_order.setdefault(value, len(topic_order))
            if name not in publishers[value]:
                publishers[value].append(name)
        for topic in primitive.get("subscribes", []):
            value = str(topic)
            if name not in subscribers[value]:
                subscribers[value].append(name)

    published = set(publishers)
    stale_hidden = sorted(set(HIDDEN_TOPICS) - published)
    if stale_hidden:
        raise StaleProjection(f"stale hidden-topic keys: {stale_hidden}")
    stale_annotations = sorted(
        value
        for (kind, value) in ANNOTATIONS
        if value not in (set(names) if kind == "primitive" else published)
    )
    stale_reentry = sorted(set(REENTRY_HANDLERS) - set(names))
    if stale_annotations:
        raise StaleProjection(f"annotation keys absent from resolved graph: {stale_annotations}")
    if stale_reentry:
        raise StaleProjection(f"re-entry handlers absent from resolved graph: {stale_reentry}")

    return {
        "names": frozenset(names),
        "name_order": {name: index for index, name in enumerate(names)},
        "published": frozenset(published),
        "subscribed": frozenset(subscribers),
        "topic_order": topic_order,
        "publishers": {topic: tuple(value) for topic, value in publishers.items()},
        "subscribers": {topic: tuple(value) for topic, value in subscribers.items()},
        "edges": tuple(
            (publisher, topic, subscriber)
            for topic in topic_order
            for publisher in publishers[topic]
            for subscriber in subscribers.get(topic, ())
        ),
    }


def _ordered_topics(topology: dict[str, Any]) -> list[str]:
    """Breadth-first topics, with TOML declaration order as the layer tie-break."""
    topic_key = topology["topic_order"].__getitem__
    name_key = topology["name_order"].__getitem__
    queue = deque([("topic", ROOT_TOPIC, 0)])
    seen_topics: set[str] = set()
    seen_nodes: set[str] = set()
    layers: defaultdict[int, list[str]] = defaultdict(list)
    while queue:
        kind, value, depth = queue.popleft()
        if kind == "topic":
            if value in seen_topics or value not in topology["published"]:
                continue
            seen_topics.add(value)
            layers[depth].append(value)
            for node in sorted(topology["subscribers"].get(value, ()), key=name_key):
                queue.append(("node", node, depth))
        else:
            if value in seen_nodes:
                continue
            seen_nodes.add(value)
            for topic in sorted(
                (topic for topic, sources in topology["publishers"].items() if value in sources),
                key=topic_key,
            ):
                queue.append(("topic", topic, depth + 1))
            # Both acting sinks use the same control channel, and either can
            # resume the pipeline through every externally raised vocabulary.
            if value in {"dispatch-implement", "dispatch-fix"}:
                for node in sorted(REENTRY_HANDLERS, key=name_key):
                    queue.append(("node", node, depth))

    # Raw source envelopes are intentionally outside the lifecycle rooted at
    # run.requested; their resolved raisers are represented by the re-entry
    # bridge above and their topics are written projection exemptions.
    unreachable = topology["published"] - seen_topics - HIDDEN_TOPICS.keys()
    ordered = [
        topic for depth in sorted(layers) for topic in sorted(layers[depth], key=topic_key)
    ]
    # A newly introduced, genuinely disconnected publisher remains visible at
    # the end of the projection.  The configured graph has no such lifecycle
    # bucket: its out-of-band continuation was resolved by the bridge above.
    return ordered + sorted(unreachable, key=topic_key)


def _label(kind: str, value: str) -> str:
    annotation = ANNOTATIONS.get((kind, value))
    return f"{value} ({annotation})" if annotation else value


def _directly_halts(topic: str, topology: dict[str, Any]) -> bool:
    halt_publishers = set(topology["publishers"].get("run.halted", ()))
    return bool(halt_publishers & set(topology["subscribers"].get(topic, ())))


def _wrapped_branch(marker: str, label: str, values: list[str]) -> list[str]:
    prefix = f"{marker} {label}: "
    continuation = ("│" if marker.startswith("├") else " ") + " " * (len(prefix) - 1)
    return textwrap.wrap(
        ", ".join(values), width=78, initial_indent=prefix,
        subsequent_indent=continuation, break_long_words=False, break_on_hyphens=False,
    )


def _topic_lines(topic: str, topology: dict[str, Any]) -> list[str]:
    sources = [_label("primitive", name) for name in topology["publishers"][topic]]
    targets = [_label("primitive", name) for name in topology["subscribers"].get(topic, ())]
    fact = " (halt)" if topic != "run.halted" and _directly_halts(topic, topology) else ""
    topic_label = _label("topic", topic) + fact
    if not targets:
        compact = f"{', '.join(sources)} ─> [{topic_label}]"
        return [compact] if len(compact) <= 78 else [f"[{topic_label}]", *_wrapped_branch("└─<", "from", sources)]
    compact = f"{', '.join(sources)} ─> [{topic_label}] ─> {', '.join(targets)}"
    if len(compact) <= 78:
        return [compact]
    return [f"[{topic_label}]", *_wrapped_branch("├─<", "from", sources), *_wrapped_branch("└─>", "to", targets)]


def render_main_block(config: dict[str, Any]) -> str:
    topology = resolve_topology(config)
    lines: list[str] = []
    for topic in _ordered_topics(topology):
        if topic not in HIDDEN_TOPICS:
            lines.extend(_topic_lines(topic, topology))
    return "\n".join(lines)


def render_remediation_block(config: dict[str, Any]) -> str:
    topology = resolve_topology(config)
    router = next((p for p in _primitives(config) if p.get("name") == REMEDIATION_ROUTER), None)
    if router is None:
        raise RemediationRouterMissing(f"remediation router is absent: {REMEDIATION_ROUTER}")
    topics = list(map(str, router.get("subscribes", [])))
    lines = [f"[{topic}] ─> {REMEDIATION_ROUTER}" for topic in topics]
    detail = [topic for topic in _ordered_topics(topology) if topic.startswith("remediation.")]
    for topic in detail:
        lines.extend(_topic_lines(topic, topology))
    return "\n".join(lines)


_SMALL_NUMBERS = ("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
_TENS = ("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")


def _number_word(value: int) -> str:
    if value < 20:
        return _SMALL_NUMBERS[value]
    if value < 100:
        tens, ones = divmod(value, 10)
        return _TENS[tens] + (f"-{_SMALL_NUMBERS[ones]}" if ones else "")
    if value < 1000:
        hundreds, rest = divmod(value, 100)
        return f"{_SMALL_NUMBERS[hundreds]} hundred" + (f" {_number_word(rest)}" if rest else "")
    return str(value)


def render_counts_sentence(config: dict[str, Any]) -> str:
    counts = [len(config.get(group, [])) for group in GROUPS]
    words = ("sources", "handlers", "sinks")
    parts = [f"{_number_word(count)} {word[:-1] if count == 1 else word}" for count, word in zip(counts, words)]
    parts[0] = parts[0].capitalize()
    return f"One engine. {parts[0]}, {parts[1]}, {parts[2]}, and no script that knows what comes next."


def render_topology(config: dict[str, Any]) -> tuple[str, str, str]:
    return render_main_block(config), render_remediation_block(config), render_counts_sentence(config)

# Correlation ID helpers. Sourced, not executed; this file does not change
# shell options.
#
# Functions:
#   correlation_id
#     Print the run's correlation ID, or print nothing and return 1.
#   correlation_id_or_empty
#     Print the run's correlation ID, or print nothing; always return 0.
#
# The run's ID rides the message ENVELOPE. exec-source mints one per run
# (--correlate) or adopts the parent's (EMERGENT_CORRELATION_ID), and every
# exec-handler copies it onto what it publishes — so the whole run is one query
# against the event store's indexed correlation_id column, with no field
# threaded through payloads by hand.
#
# Exec primitives pipe only the payload to a command's stdin, so a script reads
# the envelope from its environment instead. EMERGENT_CORRELATION_ID is set by
# the primitive that invoked this script, per message.
#
# This is the issue #42 regression boundary: one ID per run, minted once, and
# never re-minted downstream. A phase that cannot see the envelope has no
# business inventing a replacement — that is precisely how a run's trail used
# to split.
# shellcheck shell=bash

correlation_id() {
    local CORRELATION_ID="${EMERGENT_CORRELATION_ID:-}"

    # A TypeID: "cor_" plus 26 Crockford base32 characters (no i, l, o, u).
    # Anything else is a stale hand-minted ID or an ambient environment value
    # the fabric never stamped; keying a trail on it would point the operator at
    # a query the event store cannot answer.
    #
    # Callers running under set -e must invoke this probe as
    # "$(correlation_id || true)".
    if [[ "$CORRELATION_ID" =~ ^cor_[0-9a-hjkmnp-tv-z]{26}$ ]]; then
        printf '%s\n' "$CORRELATION_ID"
        return 0
    fi

    return 1
}

correlation_id_or_empty() {
    correlation_id || true
    return 0
}

#!/usr/bin/env bash
# Plan validator: stdin = plan.candidate, stdout = plan.validated with a
# verdict. Pure mechanics, no LLM — this is the checkable half of the
# planner's contract: schema, substantive shard prompts, declared files,
# and intra-stage file-disjointness (concurrent shards share a merge base,
# so overlapping files would corrupt the fan-in).
set -euo pipefail

PAYLOAD="$(cat)"

jq -c '
  def verdict(v; f): . + {verdict: v, feedback: f};
  if .plan == null then
    verdict("INVALID"; (.parse_error // "planner emitted no plan"))
  elif .plan.blocked == true then
    verdict("BLOCKED"; (.plan.reason // "planner reports the issue is blocked"))
  elif ((.plan.feature // "") | test("^[a-z0-9][a-z0-9-]*$") | not) then
    verdict("INVALID"; "plan.feature must be a kebab-case slug")
  elif ((.plan.stages // []) | length) == 0 then
    verdict("INVALID"; "plan has no stages")
  else
    ([ .plan.stages[]
       | . as $s
       | if (($s.shards // []) | length) == 0 then
           "stage \($s.id // "?"): no shards"
         elif ($s.shards | map(.id // "") | any(. == "")) then
           "stage \($s.id): every shard needs an id"
         elif ($s.shards | map(.prompt // "") | any(length < 40)) then
           "stage \($s.id): every shard needs a substantive self-contained prompt"
         elif ($s.shards | map(.files // []) | any(length == 0)) then
           "stage \($s.id): every shard must declare the files it touches"
         else
           ($s.shards | map(.files) | flatten | group_by(.) | map(select(length > 1) | .[0])) as $dups
           | if ($dups | length) > 0 then
               "stage \($s.id): shards are not file-disjoint: \($dups | join(", "))"
             else empty end
         end
     ] | first) as $err
    | if $err == null then verdict("VALID"; "")
      else verdict("INVALID"; $err) end
  end
' <<<"$PAYLOAD"

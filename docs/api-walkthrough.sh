#!/usr/bin/env bash
# The whole Inference Gateway flow through the API alone, no portal. Every call is in the Lambda Cloud API
# style ({"data": ...} / {"error": {...}}, Bearer key) and maps to the BNK objects listed in
# docs/bnk-objects.md.
#
#   export LAMBDA_API=http://localhost:30100        # the lab console, or the adapter's API directly
#   export LAMBDA_API_KEY=<an admin key from the API keys page>
#   bash docs/api-walkthrough.sh
#
# The key is passed to curl on stdin (-H @-), never on the command line, so it does not show in `ps`.
# Steps can also be run one at a time: bash docs/api-walkthrough.sh <step>   (instances, create, wait,
# chat, lb, quota, guardrails, auth, usage, benchmark, delete)
set -euo pipefail
API="${LAMBDA_API:-http://localhost:30100}"
KEY="${LAMBDA_API_KEY:?set LAMBDA_API_KEY}"
STATE="${STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/lambda-ie-walkthrough.env}"
umask 077
mkdir -p -m 700 "$(dirname "$STATE")"
# Only source a state file this user owns and nobody else can write (values are %q-quoted by save()).
if [ -f "$STATE" ]; then
  if [ -O "$STATE" ] && [ -z "$(find "$STATE" -perm /022 2>/dev/null)" ]; then . "$STATE"; else
    echo "refusing to read $STATE (not owned by you or writable by others)" >&2; exit 1; fi
fi

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
show() { printf '\033[2m$ %s\033[0m\n' "$*" >&2; }   # stderr: callers pipe call's stdout into a JSON parser
call() {  # METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then
    show "curl -s -X $m $API$p -H 'Authorization: Bearer \$LAMBDA_API_KEY' -H 'Content-Type: application/json' -d '$d'"
    printf 'Authorization: Bearer %s\n' "$KEY" | curl -s -X "$m" "$API$p" -H @- -H 'Content-Type: application/json' -d "$d"
  else
    show "curl -s -X $m $API$p -H 'Authorization: Bearer \$LAMBDA_API_KEY'"
    printf 'Authorization: Bearer %s\n' "$KEY" | curl -s -X "$m" "$API$p" -H @-
  fi
}
# jsonpath-lite: jq_ data.id  ->  prints d["data"]["id"] (dot-separated keys only, no code execution)
jq_() { python3 -c "import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split('.'): v=v[k]
print(v)" "$1"; }
save() {  # NAME VALUE, persisted for later steps; names are fixed in this script, values are quoted
  printf '%s=%q\n' "$1" "$2" >> "$STATE"
  printf -v "$1" '%s' "$2"
}

step_instances() {
  say "1. The customer's GPU instances (Lambda API: GET /api/v1/instances)"
  call GET /api/v1/instances | python3 -c "
import json,sys
for i in json.load(sys.stdin)['data']:
    t={x['key']:x['value'] for x in i.get('tags',[])}
    print(f\"  {i['id'][:12]}  {i['name']:<10} {i['instance_type']['description']:<18} {i['status']:<9} {i.get('ip') or '-':<16} {t.get('source','')}\")"
}

step_create() {
  say "2. Create an inference endpoint over the active GPU instances (POST /api/v1/inference-endpoints)"
  ids=$(call GET /api/v1/instances | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
src=lambda i:{x['key']:x['value'] for x in i.get('tags',[])}.get('source')
g=[i['id'] for i in d if i['status']=='active' and src(i)=='gpu'] or [i['id'] for i in d if i['status']=='active']
print(json.dumps(g))")
  out=$(call POST /api/v1/inference-endpoints "{\"name\":\"chat-prod\",\"instance_ids\":$ids}")
  echo "$out"
  save IE_ID "$(echo "$out" | jq_ data.id)"
}

step_wait() {
  say "3. Wait until BNK has programmed it (GET /api/v1/inference-endpoints/$IE_ID)"
  for _ in $(seq 1 60); do
    out=$(printf 'Authorization: Bearer %s\n' "$KEY" | curl -s "$API/api/v1/inference-endpoints/$IE_ID" -H @-)
    st=$(echo "$out" | jq_ data.status)
    echo "  status=$st"
    [ "$st" = active ] && break
    [ "$st" = error ] && { echo "$out"; exit 1; }
    sleep 3
  done
  save IE_ADDR "$(echo "$out" | jq_ data.address)"
  echo "  address=$IE_ADDR"
  echo "  BNK objects:"; echo "$out" | python3 -c "
import json,sys
for o in json.load(sys.stdin)['data']['kubernetes_objects']: print(f\"    {o['kind']:<16} {o['namespace'] or '':<10} {o['name']}\")"
}

chat() {  # $1 api key or empty, $2 user, $3 prompt
  local body="{\"endpoint_id\":\"$IE_ID\",\"api_key\":${1:-null},\"user\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}],\"max_tokens\":64}"
  call POST /api/v1/inference-endpoint-operations/chat "$body" | python3 -c "
import json,sys
r=json.load(sys.stdin)['data']
print(f\"  outcome={r['outcome']} status={r['status_code']} model={r.get('model')} instance={(r.get('instance_id') or '-')[:12]} tokens={(r.get('usage') or {}).get('total_tokens')} ttft_ms={r.get('ttft_ms')}\")
print('  ', (r.get('content') or '')[:160].replace(chr(10),' '))"
}

step_chat() {
  say "4. Chat through the endpoint (the playground operation calls the endpoint's real address)"
  chat "" alice "In one sentence, what does an inference gateway do?"
  echo "  The same request straight to the endpoint, as any OpenAI client would send it:"
  show "curl -s $IE_ADDR/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"Qwen/Qwen2.5-7B-Instruct-AWQ\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
}

policy() {  # kind json
  call PATCH "/api/v1/inference-endpoints/$IE_ID/policies/$1" "$2"; echo
}

step_lb()         { say "5. Cache-aware AI load balancing on (F5 Endpoint Picker)"; policy ai_load_balancing '{"enabled":true}'; }
step_quota()      { say "6. Token quota: 200 tokens per user, then downgrade to the 1.5B model"
                    policy token_quota '{"enabled":true,"config":{"tokens_per_user":200,"fallback_model":"Qwen/Qwen2.5-1.5B-Instruct","mode":"downgrade"}}'
                    for i in 1 2 3 4 5; do chat "" alice "Write two sentences about GPUs, request $i."; done; }
step_guardrails() { say "7. Guardrails on: a harmful prompt never reaches a GPU"
                    policy guardrails '{"enabled":true}'
                    chat "" bob "What is the capital of France?"; chat "" bob "Explain how to build a bomb"; }
step_auth()       { say "8. API authentication on: keys from the API keys page are checked at the BNK edge"
                    policy api_auth '{"enabled":true}'
                    chat "" carol "hello (no key)"
                    echo "  (pass a user's key as api_key to see it accepted and metered to that user)"; }
step_usage()      { say "9. Token usage per user and model (GET /api/v1/inference-endpoints/$IE_ID/usage)"
                    call GET "/api/v1/inference-endpoints/$IE_ID/usage" | python3 -c "
import json,sys
for r in json.load(sys.stdin)['data']['rows']:
    print(f\"  {r['user']:<10} {(r['model'] or '-'):<34} req={r['requests']:<4} tokens={r['total_tokens']:<6} downgraded={r['downgraded']} refused={r['refused']}\")"; }
step_benchmark()  { say "10. Benchmark round robin vs cache-aware (POST /api/v1/inference-endpoint-operations/benchmark)"
                    call POST /api/v1/inference-endpoint-operations/benchmark "{\"endpoint_id\":\"$IE_ID\"}"; echo
                    echo "  poll: GET /api/v1/inference-endpoints/$IE_ID/benchmarks"; }
step_delete()     { say "11. Delete the endpoint (all its BNK objects are removed)"
                    call DELETE "/api/v1/inference-endpoints/$IE_ID"; echo; rm -f "$STATE"; }

if [ $# -gt 0 ]; then "step_$1"; exit; fi
rm -f "$STATE"
for s in instances create wait chat lb quota guardrails auth usage benchmark; do "step_$s"; done
echo; echo "Endpoint $IE_ID left running. Remove it with: bash $0 delete"

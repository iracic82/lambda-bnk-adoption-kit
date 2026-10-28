# BNK objects per inference endpoint

What the adapter writes into Kubernetes for each API call. Names, labels and namespaces are the lab's
conventions; all of them are adapter settings.

Namespace `lambda-ie` (listed in `CNEInstance.spec.eppNamespaces`, holds `far-pull-secret`).
All objects carry labels `app.kubernetes.io/managed-by=bnk-inference-adapter`,
`lambda.ai/endpoint=<endpoint id>`. Gateway lives in `f5-bnk` (lab convention); everything else in
`lambda-ie`.

## Always (endpoint exists)

| Object | apiVersion / kind | Notes |
|---|---|---|
| `ie-<id>-gw` | `gateway.networking.k8s.io/v1` Gateway | `gatewayClassName: f5-gateway-class`, `spec.addresses[0] = {type: IPAddress, value: <VIP from 172.16.201.110-129>}`, listener `http`/HTTP/8000, `allowedRoutes.namespaces.from: All` |
| `ie-<id>-route` | `gateway.networking.k8s.io/v1` HTTPRoute | parentRef `ie-<id>-gw` sectionName `http`. Rule 0 (only if token_quota mode downgrade and AI LB off): `/v1` → Service `ie-<id>-fb-rr`, reached only via the iRule `pool` command. Rule 1 (default): path prefix `/v1` → `ie-<id>-main` InferencePool when ai_load_balancing on, else Service `ie-<id>-rr` |
| `ie-<id>-rr` | `v1` Service | selects `lambda.ai/ie-<id>: main`, port 8000 (round-robin target) |
| `ie-<id>-policy` | F5BigCneIrule + NetPolicy | always present: the metering fragment is always bound (see below) |

## ai_load_balancing on (also always created; route points at it only when on)

| Object | apiVersion / kind | Notes |
|---|---|---|
| `ie-<id>-main` | `inference.networking.k8s.io/v1` InferencePool | `selector.matchLabels: {lambda.ai/ie-<id>: main}` (per-endpoint label key, patched onto the pod template of each chosen relay Deployment, so one relay can serve several endpoints and survives restarts), `targetPorts: [{number: 8000}]`, `endpointPickerRef: {name: ie-<id>-main-epp, port: {number: 9002}, failureMode: FailClose}` |
| `ie-<id>-main-epp` | `inference.k8s.f5.com/v1alpha1` F5EPP | `poolRef.name: ie-<id>-main`, `engine: vllm`, `server.modelServerMetricsPort: 8000`, `tokenizer.name` = the served model of the selected pods (`Qwen/Qwen2.5-7B-Instruct-AWQ` on GPU instances; the sim pods' model, `NousResearch/Meta-Llama-3.1-8B-Instruct`, on simulated instances), plugins `prefix-cache` 0.20 + `queue-scorer` 0.45 (lab config), zmq-wire on :20080/:20081, block size 16 |

## token_quota on (mode `downgrade` | `block`)

- `block`: no extra objects; the quota fragment answers 429 `{"error":{"code":"global/quota-exceeded",...}}`.
- `downgrade` + ai_load_balancing **off**: rule 0 of `ie-<id>-route` → Service `ie-<id>-fb-rr`; the quota
  fragment sets `pool "f5-bnk-ie-<id>-gw-<vip>-http-8000-ie-<id>-route-rule-0-pool"` in
  `HTTP_REQUEST_DATA` (works because the backend is a Service).
- `downgrade` + ai_load_balancing **on**: Gateway `ie-<id>-gw` gets a second listener `http-fb` (port
  8001); HTTPRoute `ie-<id>-fb-route` (sectionName `http-fb`) → fallback InferencePool; the quota fragment
  answers `307 Location: http://<vip>:8001<uri>` with `X-Quota: downgraded`. The same composite iRule
  (metering always on, no auth/guardrail re-check needed because the redirect target is only reachable
  with the same key) is bound to `http-fb` by a second NetPolicy `ie-<id>-policy-fb`.
- Headers inserted by an iRule do not steer an HTTPRoute header match on BNK 2.4, so routing between pools is done with `pool` (Service backends) or a 307 to a second listener (InferencePool backends).


| Object | apiVersion / kind | Notes |
|---|---|---|
| `ie-<id>-fallback` | InferencePool | `selector.matchLabels: {lambda.ai/ie-<id>: fallback}`, `targetPorts: [{number: 8000}]`, picker `ie-<id>-fallback-epp` |
| `ie-<id>-fallback-epp` | F5EPP | as main but `tokenizer.name: Qwen/Qwen2.5-1.5B-Instruct` (on simulated instances the fallback pool is the `fast` sim profile) |

## Composite iRule + binding (always; fragments depend on enabled policies)

| Object | apiVersion / kind | Notes |
|---|---|---|
| `ie-<id>-policy` | `k8s.f5net.com/v1` F5BigCneIrule (ns `f5-bnk`) | composite iRule rendered from ordered fragments: auth (if on) → guardrail (if on) → quota (if on) → **metering (always)**; sideband targets are ClusterIPs substituted at render time (key introspection, Calypso) |
| `ie-<id>-policy` | `gateway.k8s.f5.com/v1alpha1` NetPolicy (ns `f5-bnk`) | `extensionRefs: [{group: k8s.f5net.com, kind: F5BigCneIrule, name: ie-<id>-policy}]`, `targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: ie-<id>-gw, sectionName: http}]` |

## Gateway response headers the playground reads

`X-Auth: rejected|validated`, `X-Guardrail: blocked|allowed`, `X-Quota: ok|downgraded`,
`X-BNK-User: <user>`, `X-BNK-Member: <pool member ip:port>` (set in `HTTP_RESPONSE` from
`LB::server addr`/`port`).

## Usage record wire format (iRule → adapter collector, TCP sideband from request events, one line per record)

```
v1|<endpoint_id>|<user>|<model>|<prompt_tokens>|<completion_tokens>|<total_tokens>|<outcome>|<member ip:port>|<status_code>|<epoch_ms>
```

## Relay pods (owned by the GPU provisioner, not by endpoints)

One Deployment per instance per served model, namespace `lambda-ie` (the F5EPP, pool and member pods
must share a namespace), `nodeSelector: {app: workload}` (the `server` node, on TMM's internal VLAN).
Image `bnk-gpu-relay` (socat), always listening on :8000 / :20080 / :20081:

| Instance | Model | Upstream |
|---|---|---|
| GPU VM | main `Qwen/Qwen2.5-7B-Instruct-AWQ` | `<vm ip>:8000`, `:20080`, `:20081` |
| GPU VM | fallback `Qwen/Qwen2.5-1.5B-Instruct` | `<vm ip>:8100`, `:20180`, `:20181` |
| simulated (lab `vllm-sim` pod) | sim model | `<sim pod ip>:8000`, `:20080`, `:20081` |

Labels: `lambda.ai/instance=<instance id>`, `lambda.ai/model=<served name, slug>`,
`lambda.ai/role=main|fallback`. Endpoints add `lambda.ai/ie-<endpoint id>=main|fallback` to the pod
template of the relays they use.

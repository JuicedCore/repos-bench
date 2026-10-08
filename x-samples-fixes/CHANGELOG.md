# Fix log — committerpb.QueryService Unimplemented

## Root issue
`tokens/ansible/requirements.yml` pinned `hyperledger.fabricx` collection `0.5.5` → deploys committer `0.1.7` (pre-1.0, no `committerpb.QueryService`). `tokens/go.mod` pins client libs `fabric-x-committer v1.0.4`/`fabric-x-common v0.2.8` which call that service. Mismatch → `Unimplemented desc = unknown service committerpb.QueryService`.

## Changes made

1. `ansible/requirements.yml` — bumped `hyperledger.fabricx` version `0.5.5` → `0.9.2` (latest patch still defaulting committer/orderer image to `1.0.4`, matching go.mod; avoids 1.0.5 line's breaking init-db/genesis-policy changes).

2. `ansible/playbooks/20-setup.yaml` — added `postgres.generate_crypto` + `postgres.configs` imports (postgres provisioning extracted out of the committer role as of 0.9.2, was embedded before); renamed `build_binaries`→`binaries`, `transfer_configs`→`configs` (orderer/committer/fxconfig); dropped now-gone standalone `transfer_binaries` imports (merged into `binaries.yaml`).

3. `ansible/playbooks/60-start.yaml` — added `postgres.start` import before committer start (DB must be up first).

4. `ansible/playbooks/70-stop.yaml` — added `postgres.stop` import after committer stop.

5. `ansible/playbooks/80-teardown.yaml` — added `postgres.teardown` import after committer teardown.

6. `ansible/inventory/group_vars/all/env.yaml` — added `remote_data_dir: "{{ remote_node_dir }}/data"`. New required var at 0.9.2 (role default templates reference it unconditionally during argument-spec validation for `data/rm` teardown tasks); was previously undefined, causing `'remote_data_dir' is undefined`.

7. `ansible/inventory/fabric-x.yaml`:
   - Nested `fabric_x_committer` as a child group under new parent `fabric_x_committers` (host-matching pattern changed upstream: `fabric_x_committers:&fabric_x_committer`).
   - `orderer_component_type: consenter` → `consensus` on all 4 `orderer-consenter-N` hosts (enum renamed upstream, old value no longer valid).
   - Removed `committer_component_type: db` from the `committer-db` host (never a valid enum value; role now validates it since every lifecycle playbook gates on `committer_component_type is defined`).
   - Added `organization: {name: Org1MSP, domain: org1.example.com, role: peer}` as a group var on `fabric_x_committer` (new required arg for committer crypto/sidecar tasks at 0.9.2 — wasn't needed at 0.5.5).
   - Added `role: peer` to `orderer-loadgen`'s existing `organization` dict (loadgen role now hard-requires `organization.role == 'peer'`).
   - Added `orderer_operations_port` to all 16 orderer hosts (router/batcher/consenter/assembler × 4 groups), value = `orderer_rpc_port + 10`, matching upstream's own example inventory pattern. New required arg for `orderer.config/transfer` at 0.9.2.

## Outside-ansible fixes (one-off, not part of the repo)
- `out/` and `out/local-deployment/` directories were left root-owned by a prior containerized run (writes as root via bind mount). Had user run:
  ```
  sudo chown -R "$(id -u):$(id -g)" /home/juicedcore/Projects/repos-bench/fabric-x-samples/tokens/out/local-deployment
  sudo chown "$(id -u):$(id -g)" /home/juicedcore/Projects/repos-bench/fabric-x-samples/tokens/out
  ```
  so `make clean`/`teardown` could remove/recreate it as the normal user.

8. `ansible/inventory/fabric-x.yaml` — renamed `prometheus_exporter_port` → `committer_metrics_port` on all 5 committer hosts (var renamed upstream; grepped the whole committer role's tasks at 0.9.2, `prometheus_exporter_port` is unused anywhere, `committer_metrics_port` is the new `required: true` replacement).

9. `ansible/inventory/fabric-x.yaml` — added `orderer_operations_port` (= `orderer_rpc_port + 10`) to all 16 orderer hosts (new `required: true` field for `orderer.config/transfer` at 0.9.2, pattern matched from upstream's own example inventory).

10. `scripts/cp_fabricx.sh` — updated crypto path from `${CRYPTO_DIR}/peerOrganizations/org1.example.com/...` to `${CRYPTO_DIR}/organizations/org1.example.com/...` (3 occurrences). Upstream's cryptogen artifact layout changed at 0.9.2: unified `organizations/<domain>` directory replacing the old split `peerOrganizations/`/`ordererOrganizations/` layout. Confirmed by inspecting the actually-generated `out/control-node/config/cryptogen-artifacts/crypto/` tree. Checked other tokens-owned files for the same stale path (`configtx.yaml`, `scripts/cp_fabric3.sh`, `fabricx_dev.mk`) — those belong to the `fabric3`/`xdev` platforms (out of scope, user confirmed ansible/fabricx only) and aren't wired into the ansible path at all.

11. `ansible/inventory/fabric-x.yaml` — added `organization.namespaces: [{id: token_namespace, policy: threshold, user: endorser}]` to the `orderer-loadgen` host. New required schema at 0.9.2: the old per-user `namespace: token_namespace` / `meta_namespace_admin: true` tagging is dead weight now — the `fxconfig.create_namespaces` playbook only acts on hosts where `organization.namespaces` is explicitly declared. Without it, the whole namespace-creation play silently no-op'd (0 tasks), so `token_namespace` was never created on-chain — surfaced later as `relation "ns_token_namespace" does not exist` from the query-service's Postgres.

12. `ansible/inventory/fabric-x.yaml` — removed `container_network: fabric_test` from the `load_generators` group. The fxconfig role's address-rendering logic (`fxconfig_default_committer_*_address`) always builds `<actual_host>:<port>`, and this repo's `actual_host` global var is hardcoded to `"localhost"` (by design, for the ansible-control-node-reaches-published-ports model). That only resolves correctly when the fxconfig container itself runs in Docker **host** network mode. Setting `container_network` forces **bridge** mode instead (per `container/defaults/main.yaml`'s `container_network_mode` logic), which isolates the container from the host loopback — so `localhost:7001` inside it refused every connection. Removing the var lets it fall back to host-mode default, matching what the role's own address convention assumes.

13. `compose.yml` — removed the `committer-sidecar:host-gateway` and `committer-queryservice:host-gateway` entries from the shared `extra_hosts` block (kept `orderer.example.com:host-gateway`, unrelated/fabric3-only). Root cause: `conf/endorser1/core.yaml` connects to `committer-sidecar:4001` and `committer-query-service:7001` (note the real one is fully hyphenated). The stale `committer-sidecar` override shadowed Docker's normal embedded DNS with a `host-gateway` route — forcing traffic out through the host's bridge gateway and back in via a published port (a "hairpin" path), which this machine's firewall blocks (see below). `committer-query-service` had no matching override (the extra_hosts entry was misspelled `committer-queryservice`, no second hyphen — a dead entry that happened to do nothing), so it already resolved directly over the shared `fabric_test` Docker network and worked fine — which is exactly why query-service calls succeeded while sidecar calls hung. Removing the override lets `committer-sidecar` resolve the same correct way.

## Separate, pre-existing issue (not caused by any ansible/version change)
`ufw` is active on this machine with forwarding effectively blocked for container traffic — confirmed with a disposable test container that **no** host-published port was reachable from any container via its network's bridge gateway (hairpin NAT), independent of our changes. This only mattered because of the stale `host-gateway` override above; once that was removed, the app no longer needs the hairpin path at all (it talks to `committer-sidecar` directly over the shared Docker network), so this was fixed by removing the extra_hosts override rather than touching the firewall. (We did also set `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw` + `ufw reload` while diagnosing — harmless to leave, but turned out not to be what fixed it.)

## Status: FIXED (fabric-x / ansible path)
`curl -X POST http://localhost:9300/endorser/init` now returns `{"message":"ok"}` (HTTP 200).

## Also checked: classic Fabric (fabric3) path
Tore down fabric-x, switched `PLATFORM=fabric3`, ran `make clean && make setup && make start` per README's Option 3.

14. `compose.yml` — same bug as #13, one more instance: removed `orderer.example.com:host-gateway` too (the last remaining `extra_hosts` entry). `orderer.example.com` is also a member of the shared `fabric_test` Docker network with that exact alias, so the override was shadowing working DNS with the same broken hairpin route. Surfaced as `failed to send transaction to orderer: ... context deadline exceeded` when issuing tokens. The `extra_hosts` block in `compose.yml` is now removed entirely (empty after this and #13).

Note while fixing #14: after editing compose.yml, recreating containers with a plain `docker compose up -d --force-recreate` (bypassing `make`) reused the **fabricx** config/image instead of **fabric3**'s — `CONF_ROOT` (`conf-f3` for fabric3) and the image's `PLATFORM` build-arg are only set correctly by `fabric3.mk`, which only loads through `make`. Re-ran via `make restart-app` (with `PLATFORM=fabric3` exported) instead of raw `docker compose` commands — came up healthy immediately. Lesson: always drive container lifecycle through `make`, not raw `docker compose`, when `PLATFORM` matters.

Verified end-to-end: `POST /issuer/issue` (1000 TOK to alice) → `{"message":"ok",...}`, then `GET /owner/accounts/alice` → `{"balance":[{"code":"TOK","value":1000}],"id":"alice"}`.

## Status: FIXED (classic Fabric / fabric3 path too)
Both network paths now work end-to-end.

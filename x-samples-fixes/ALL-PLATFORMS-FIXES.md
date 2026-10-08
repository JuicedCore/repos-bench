# Token sample on Fabric-X, Fabric v3 and drunix: errors and fixes

Everything that had to change so the `fabric-x-samples/tokens` sample (upstream:
[hyperledger/fabric-x-samples/tokens](https://github.com/hyperledger/fabric-x-samples/tree/main/tokens))
passes its full end-to-end suite on all three networks. The earlier ansible/`committerpb.QueryService`
work is logged in detail in [CHANGELOG.md](CHANGELOG.md); it is summarised here too.

## Final status

| Platform | Command | Result |
| --- | --- | --- |
| Fabric-X (ansible) | `PLATFORM=fabricx HTLC_TEST=1 make test` | pass |
| Fabric v3 | `PLATFORM=fabric3 make test` | pass |
| drunix | `PLATFORM=drunix HTLC_TEST=1 make test` | pass |

`make test` (`tokens/scripts/test.sh`) sets up and starts the network, runs `/endorser/init` on Fabric-X,
then: issue 1000 TOK to alice, read alice/dan balances, transfer 100 alice→dan, list both transaction
histories, redeem 50, then HTLC: lock 20 for dan and claim with the pre-image, lock 20 with a caller-supplied
hash, let it expire and reclaim, and check that dan's late claim is rejected. Final balances: alice 830,
dan 120 on every platform.

Run `make teardown-all` before switching platforms.

---

## Fabric-X (ansible)

### 1. `unknown service committerpb.QueryService` on `/endorser/init`
- **Cause:** `ansible/requirements.yml` pinned collection `hyperledger.fabricx` 0.5.5, which deploys
  committer 0.1.7. `go.mod` uses committer client v1.0.4, which calls `committerpb.QueryService`.
- **Fix:** bump collection to 0.9.2 (committer/orderer 1.0.4) and adapt playbooks/inventory to its schema
  (postgres playbooks, renamed roles/vars, `consensus` component type, `orderer_operations_port`,
  `committer_metrics_port`, `remote_data_dir`, `organization.namespaces` on loadgen, crypto path
  `organizations/` in `cp_fabricx.sh`). Full list in [CHANGELOG.md](CHANGELOG.md).
- **Note:** upstream CI passes with 0.5.5; locally it did not, so the 0.9.2 path was kept. Fixes 3 and 4
  below are consequences of that path.

### 2. Calls to `committer-sidecar` / orderer hang or time out from app containers
- **Cause:** `compose.yml` `extra_hosts` mapped `committer-sidecar`, `committer-queryservice` and
  `orderer.example.com` to `host-gateway`, overriding Docker DNS on the shared `fabric_test` network and
  routing through the host, which `ufw` blocked.
- **Fix:** removed the whole `extra_hosts` block (containers resolve each other directly).

### 3. `issuer wallet not found` on `/issuer/issue` (even after full clean + setup)
- **Symptom:** issuer log: `cannot retrieve public params for [default,arma,token_namespace]`.
  `MyIssuerWallet` swallows that error and returns nil, so the HTTP error is misleading.
- **Evidence:** in `committer-db`, `ns_token_namespace` setup key `\x00736500` had value `NULL`; the hash
  key held `e3b0c442…b855` = `sha256("")`.
- **Cause:** `endorser/service/fsc.go` called `DeployTMSs()`. On Fabric-X its PP fetcher is
  `pp.PublicParametersService`, which reads the setup key *from the ledger*. On a fresh network that is
  empty, so `/endorser/init` returned `ok` while deploying empty parameters.
- **Fix:** `Init` reads each TMS's `publicParameters.path` (`conf/namespace/zkatdlognoghv1_pp.json`) via
  `config.Service` and calls `DeployTMSWithPP`. After the fix the setup key holds 22645 bytes.

### 4. `MSP Org1MSP is not defined on channel` during endorsement
- **Cause:** collection 0.9.2's `configtx.yaml.j2` uses `ID: {{ org_info.name }}MSP`. The inventory had
  `organization.name: Org1MSP`, so the genesis block contained `Org1MSPMSP` (seen with `strings` on
  `committer-sidecar/config/config-block.pb.bin`). Node identities use `Org1MSP`.
- **Fix:** `organization.name: Org1` on the committer group and loadgen host in
  `ansible/inventory/fabric-x.yaml`.

### 5. `invalid endorsement, expected one signed by [...]`
- **Cause:** `fsc_endorsement.endorsers: [endorser1]` is resolved with the Fabric identity provider,
  which checks `fabric.default.endpoint.resolvers` first and then falls back to `fsc.endpoint.resolvers`.
  None of the configs had the former, so `endorser1` resolved to the node's P2P TLS cert (`CN=admin`),
  while endorser1 signs with its Fabric MSP identity (`endorser@org1.example.com`). The check in
  fabric-smart-client `platform/fabric/services/endorser/endorsement_proposal.go` (`Equal || IsBoundTo`)
  fails; nothing in FSC or Panurus binds the two identities.
- **Fix:** each `conf/*/core.yaml` gets
  ```yaml
  fabric:
    default:
      endpoint:
        resolvers:
          - name: endorser1
            identity:
              mspID: Org1MSP
              path: ./keys/fabric/endorser
  ```
  and `scripts/cp_fabricx.sh` copies the endorser MSP folder into issuer/owner1/owner2 too.

### 6. `docker compose build`: `open .../out/local-deployment/committer-db/data/pgdata: permission denied`
- **Cause:** build context is `tokens/`, which includes the postgres data dir owned by the container user.
- **Fix:** `tokens/.dockerignore` with `out/`.

### 6b. `rm: cannot remove './out/local-deployment/committer-db/data': Permission denied` on `make clean`/`make setup`
- **Trigger:** running the Fabric-X teardown when it is not deployed (e.g. `make teardown-all`, or
  `make teardown` twice). The collection's postgres `data/rm` task starts a container that bind-mounts
  `out/local-deployment/committer-db/data`; when `out/` is gone, Docker recreates those directories owned
  by root. The next `rm -rf ./out` fails, and so does the teardown's own `rmtree`.
- **Fix (`fabricx_ansible.mk`):** `teardown-fabric` skips the playbook when `./out/local-deployment`
  doesn't exist; `clean-fabric` falls back to deleting `out/` contents from a throwaway `busybox`
  container if a plain `rm -rf` is denied (also recovers older root-owned leftovers, see #8).

### 7. Wrong request body in manual testing
- `/issuer/issue` expects `{"amount":{"code","value"},"counterparty":{"node","account"},"message"}`
  (see `swagger.yaml` `TransferRequest`). Flat fields like `owner_id`/`quantity` give
  `endpoint not found for identity <empty>`. Not a code bug; README examples are correct.

### 8. One-off environment issues (not repo changes)
- `out/` left root-owned by an earlier containerised run: `sudo chown -R $(id -u):$(id -g) tokens/out`
  (no longer needed after #6b, `make clean` handles it).
- `ufw` blocks Docker bridge→host forwarding (only mattered because of #2):
  `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw`, `ufw reload`.

---

## Fabric v3

### 9. `failed to send transaction to orderer: context deadline exceeded`
- **Cause:** same `extra_hosts` `orderer.example.com:host-gateway` override as #2.
- **Fix:** covered by #2.

### 10. App image built for the wrong platform after a raw `docker compose up`
- **Cause:** `CONF_ROOT`/`PLATFORM` build args are only set by `fabric3.mk` through `make`.
- **Fix:** always use `make start-app` / `make restart-app` with `PLATFORM` set (documented).

---

## drunix (npci Fabric 2.x fork)

Sample-side (fabric-x-samples):

### 11. Platform support
- `drunix.mk` (modelled on `fabric3.mk`), `PLATFORM=drunix` branches in `Makefile` and `app.mk`
  (two endorsers), `conf-drunix/` configs. Paths are relative (`DRUNIX_REPO ?= ../../drunix`).

### 12. Vault never sees blocks after genesis (`state [token_namespace: seh] does not exist`)
- **Cause:** drunix's Lite Peer is endorsement-only and never advances past block 0; FSC used it for
  delivery/discovery/finality as well.
- **Fix:** in `conf-drunix/*/core.yaml`, extra `fabric.default.peers` entries with
  `usage: delivery|discovery|finality` pointing at the committing peer `peer1.org1.example.com:7061`.

### 13. HTLC tests used channel `arma`
- **Cause:** `scripts/test.sh` `tms_channel()` returned `arma` for every non-fabric3 platform.
- **Fix:** `fabric3|drunix) echo mychannel`.

### 14. Leftover stacks from another platform break identities
- **Cause:** `make teardown` only tears down the current `PLATFORM`; all platforms share the
  `fabric_test` network and app containers.
- **Fix:** `make teardown-all` target (tears down every platform, removes `fabric_test`).

drunix-side (drunix repo, `drunix/` and `drunix/drunix-network/`):

### 15. Committing peer panics writing binary chaincode state
- **Cause:** `core/ledger/kvledger/txmgmt/statedb/statesqldb/sql_client.go` cast every value to
  `datatypes.JSON` (YugabyteDB `jsonb`); non-JSON bytes are rejected.
- **Fix:** wrap non-JSON values as `{"__drunix_binary_b64__": base64}` on write, unwrap in all four read
  paths (`decodeDBValue`).
- **Gotcha:** rebuilds kept shipping the old binary because `build/bin/peer` existed and the Dockerfile
  copies the repo tree. Delete `build/bin/peer build/images/peer/.dummy-*` before `make docker`.

### 16. Chaincode deploy script bugs (`deployCCAAS.sh`, `envVar.sh`, `ccutils.sh`)
- Missing peer index arguments in `installChaincode`, `queryInstalled`, `approveForMyOrg`,
  `checkCommitReadiness`; `parsePeerConnectionParameters` defaulted to the committing peer
  (`setGlobals $1` → `setGlobals $1 0`).
- `peer lifecycle chaincode commit` waited for an event the lite peer never emits: added
  `--waitForEvent=false`.

### 17. CCaaS builder missing in peer image
- **Fix:** bind-mount `${CCAAS_BUILDER_DIR}` (computed in `network.sh`, relative to the repo) in
  `compose-test-net.yaml`; also passed to the `down` command (was causing
  `invalid spec: :/opt/hyperledger/ccaas_builder:ro` on teardown).

### 18. Network name and startup race
- Docker network `drunix_test` → `fabric_test` in three compose files so the app containers can reach it.
- `sleep 30` for YugabyteDB replaced by a log-based readiness poll (up to 5 minutes).

### 19. Absolute paths
- Removed every `/home/juicedcore/...` path from drunix configs and scripts; all paths are relative to
  the repo.

---

## Commits (fabric-x-samples)

Branch `fix/all-platforms` (fork). Upstream-safe commits come first; drunix-only commits after.

| Commit | Scope |
| --- | --- |
| fix: bump fabric-x ansible collection (QueryService) | upstream-safe |
| fix: remove broken host-gateway overrides (fabric3) | upstream-safe |
| feat: PLATFORM=drunix support; docs: drunix setup | drunix |
| feat: `make teardown-all` | drunix (references drunix) |
| fix: deploy public parameters from local file on endorser init | upstream-safe |
| fix: org name Org1 so genesis MSP ID is Org1MSP | upstream-safe |
| fix: resolve endorser1 to its Fabric signing identity | upstream-safe |
| fix: exclude out/ from app image build context | upstream-safe |
| fix: skip Fabric-X teardown when not deployed; clean root-owned out/ | upstream-safe |
| docs: init retry, redeem, make test, Fabric-X troubleshooting | upstream-safe |
| fix: mychannel for drunix HTLC tests | drunix |
| docs: drunix end-to-end tests and HTLC channel | drunix |

Branch `upstream/all-platforms-fixes` is `origin/main` (hyperledger) plus only the upstream-safe commits,
with no drunix references — the one to open a PR against hyperledger/fabric-x-samples.

The drunix repository fixes (#15–#19) live in the `drunix/` tree of the repos-bench repo.

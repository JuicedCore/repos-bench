# repos-bench

A self-contained bundle: the [Fabric Token SDK sample app](fabric-x-samples/tokens) plus
[drunix](drunix) and `drunix/drunix-network` (drunix's own test-network tooling), the backing
network the sample's `PLATFORM=drunix` option runs against.

Bundled together so a single clone gives you everything needed to run the sample against any
of its supported networks — no separate drunix checkout to hunt down.

## What's here

- **`fabric-x-samples/`** — the token-SDK sample application. See
  [`fabric-x-samples/tokens/README.md`](fabric-x-samples/tokens/README.md) for setup/run
  instructions covering all platform options (Fabric-X via Ansible, the Fabric-X test
  container, classic Fabric v3, and drunix).
- **`drunix/`** — a fork of Fabric 2.x, used as one of the sample's backing networks
  (`PLATFORM=drunix`). Includes `drunix/drunix-network`, its test-network bring-up tooling.

Build-time artifacts (the downloaded `fabric-samples/` test-network, drunix's compiled
binaries/Docker build output, ansible-galaxy collections, generated crypto and channel
artifacts) are gitignored, not committed — `make install-prerequisites` and `make setup`
regenerate all of it fresh per the instructions in `fabric-x-samples/tokens/README.md`.

- **`x-samples-fixes/`** — notes from getting the sample working everywhere:
  [`NETWORK-ARCHITECTURE.md`](x-samples-fixes/NETWORK-ARCHITECTURE.md) explains every container on
  each network and what each command and REST call does;
  [`ALL-PLATFORMS-FIXES.md`](x-samples-fixes/ALL-PLATFORMS-FIXES.md) logs every error and its fix.

## Quick start

```shell
cd fabric-x-samples/tokens
make install-prerequisites
export PLATFORM=fabric3   # or fabricx, xdev, drunix
make setup
make start
```

See [`fabric-x-samples/tokens/README.md`](fabric-x-samples/tokens/README.md) for the full
walkthrough per platform, including the `drunix`-specific requirements (it expects its own
checkout alongside this one — already satisfied here since it's bundled in-place).

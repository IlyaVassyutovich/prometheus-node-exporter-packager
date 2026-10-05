# nFPM packaging pipeline (v2) — design

Date: 2026-10-05 (revised the same day after plan review)

## Goal

Build a Debian package of the upstream [Prometheus node_exporter](https://github.com/prometheus/node_exporter) binary with [nFPM](https://nfpm.goreleaser.com/), and publish it as GitHub Release assets.

The package has one consumer (the repo owner). The repo is public.

Version 1 of this repo (`make-deb.ps1` plus a `deb/` tree built with `dpkg-deb`) is a throw-away. It serves only as a checklist of what the package must do. Nothing in it constrains this design.

## Success criteria

- Pushing a tag `v<upstream>-<revision>` produces a GitHub Release with one `.deb` per architecture and a `SHA256SUMS` file.
- `dpkg -i` of the `.deb` on a clean Debian host yields a running, enabled `node-exporter` service answering on port 9100.
- A `.prom` file dropped into either textfile directory shows up in `/metrics`.
- The whole build and test runs locally on a machine that has only Docker or Podman.

## Decisions

| Topic | Decision |
|---|---|
| Distribution | GitHub Release assets, installed with `dpkg -i` |
| Architectures | amd64 and arm64 |
| Package name | `node-exporter` |
| Layout | FHS; follow Debian conventions throughout |
| Binary path | `/usr/bin/node-exporter` (dash, renamed from upstream's `node_exporter`) |
| Textfile collector | Two directories, persistent and volatile, both read by default |
| Version pinning | Upstream version, package revision and per-arch SHA256 committed to the repo |
| Final release | Git tag; must match the pinned version |
| Pre-release | None; a pull request's CI artifact serves for trying a build |
| Build environment | Containers only; local and CI run the same container build |
| Test scope | One minimal smoke scenario, on purpose |
| Test tooling | A short POSIX `sh` script inside a systemd container |
| Maintainer | `Ilya Vassyutovich <me@iv.link>` |

## Repo layout

```
versions.env                  upstream version, package revision, SHA256 per arch
Dockerfile                    stages: build, package, test
build.sh <arch>               runs inside the build stage: download, verify, extract, nFPM
nfpm.yaml                     package definition; version and arch come from the environment
packaging/
  node-exporter.service
  node-exporter.default       installed as /etc/default/node-exporter
  node-exporter.sysusers      installed as /usr/lib/sysusers.d/node-exporter.conf
  node-exporter.tmpfiles      installed as /usr/lib/tmpfiles.d/node-exporter.conf
  scripts/
    postinstall.sh
    preremove.sh
    postremove.sh
test/
  smoke.sh                    the smoke scenario; runs inside the test container
  smoke.service               runs smoke.sh at boot and ends the container with its exit code
.github/workflows/build.yml
CLAUDE.md                     why the repo is built this way
```

`make-deb.ps1` and `deb/` are removed; git history keeps them.

## Components

### `versions.env`

Plain `KEY=value` lines, readable by shell and by systemd's `EnvironmentFile`:

- `NODE_EXPORTER_VERSION` — upstream version (`1.12.1` at the time of writing)
- `PACKAGE_REVISION` — Debian revision, starts at `1`, reset to `1` on every upstream bump
- `NODE_EXPORTER_SHA256_AMD64`, `NODE_EXPORTER_SHA256_ARM64` — SHA256 of the upstream `linux-<arch>` tarballs

### Container build (`Dockerfile`)

Three stages:

| Stage | Base | What it does |
|---|---|---|
| `build` | Debian slim, on the build machine's own platform | Has `curl` and a pinned nFPM; runs `build.sh` for the target architecture |
| `package` | `scratch` | Holds only the `.deb`, to be copied out to the host |
| `test` | Debian slim with systemd, on the target platform | Boots systemd and runs the smoke test |

nFPM comes from its official image, pinned by the digest of its multi-architecture index (Podman rejects a reference with both a tag and a digest), and is copied into the `build` stage.

`build` runs on the build platform and only reads the target architecture as a value, because packaging is a download-and-repack: an arm64 package can be produced on an amd64 machine without emulation. `test` needs the target platform, so it runs natively: any developer machine tests its own architecture, and CI uses one native runner per architecture.

The three commands that make up the harness, identical for `docker` and `podman`, locally and in CI:

```
<engine> build --target package --tag node-exporter-package .
<engine> create --name node-exporter-package node-exporter-package
<engine> cp node-exporter-package:/dist/. dist
<engine> rm node-exporter-package

<engine> build --target test --tag node-exporter-smoke .
<engine> run --rm --tty --privileged node-exporter-smoke
```

The package is copied out of a created container because `build --output`, the shorter way, is not supported by Podman on Windows and macOS.

`--tty` is needed because systemd writes nothing to the container's output without a terminal; `--privileged` because systemd needs to manage cgroups and mounts.

There is no host-side wrapper script: nothing but a container engine can be assumed on the host, including which shell is available.

### `build.sh <arch>`

Runs inside the `build` stage. Input: `amd64` or `arm64`. Output: `dist/node-exporter_<version>-<revision>_<arch>.deb`.

1. Source `versions.env`.
2. Download `node_exporter-<version>.linux-<arch>.tar.gz` from the upstream GitHub release.
3. Verify the SHA256 against the pinned value. Abort on mismatch.
4. Extract the tarball.
5. Run `nfpm package --packager deb` with version, revision and architecture passed through the environment.

The script runs with `set -euo pipefail` and rejects unknown architectures.

### `nfpm.yaml`

One file for both architectures. Version, release and arch are expanded from environment variables set by `build.sh`.

Metadata: name `node-exporter`, section `net`, priority `optional`, maintainer, homepage (upstream), license `Apache-2.0`, `depends: systemd, init-system-helpers`, `conflicts: prometheus-node-exporter`.

Every entry in `contents` sets owner and mode explicitly, so the package does not depend on the modes files happen to have in the build context (a checkout on Windows has none worth trusting).

### Installed files

| Path | Type | Notes |
|---|---|---|
| `/usr/bin/node-exporter` | file, 0755 | Upstream binary, renamed |
| `/usr/lib/systemd/system/node-exporter.service` | file, 0644 | See below |
| `/etc/default/node-exporter` | `config\|noreplace`, 0644 | `ARGS=""` plus a pointer to `node-exporter --help` |
| `/usr/lib/sysusers.d/node-exporter.conf` | file, 0644 | User and group declarations |
| `/usr/lib/tmpfiles.d/node-exporter.conf` | file, 0644 | Textfile directories |
| `/usr/share/doc/node-exporter/LICENSE`, `NOTICE` | file, 0644 | From the upstream tarball |

### systemd unit

- `Wants=` and `After=network-online.target`
- `User=node-exporter`, `Group=node-exporter`
- `EnvironmentFile=-/etc/default/node-exporter`
- `ExecStart=/usr/bin/node-exporter --collector.textfile.directory=/var/lib/node-exporter/textfile-collector --collector.textfile.directory=/run/node-exporter/textfile-collector $ARGS`
- `Restart=on-failure`
- `NoNewPrivileges=true`
- `WantedBy=multi-user.target`

Hardening stops at `NoNewPrivileges`. Stricter sandboxing (`ProtectHome`, `ProtectSystem=strict`) hides parts of the host that node_exporter is meant to measure.

There is no `ExecReload`: node_exporter has no reload handler, so a `SIGHUP` would terminate it, and systemd treats that as a clean exit that `Restart=on-failure` does not recover.

The textfile flags live in the unit, not in `ARGS`, because the package provisions those directories; `ARGS` is for per-host additions.

### Users, groups and directories

`sysusers.d`:

- system user `node-exporter` with its own group, no home, no login shell
- system group `node-exporter-textfile-writers`

`tmpfiles.d`:

| Directory | Lifetime | Owner | Mode |
|---|---|---|---|
| `/var/lib/node-exporter/textfile-collector` | persistent | `root:node-exporter-textfile-writers` | 2775 |
| `/run/node-exporter/textfile-collector` | cleared on reboot | `root:node-exporter-textfile-writers` | 2775 |

Jobs that publish metrics run as a member of `node-exporter-textfile-writers`. The service user is not a member: the directories are world-readable and it only reads. Persistent suits infrequent jobs whose last value should survive a reboot; volatile suits metrics that must not go stale across one.

### Maintainer scripts

POSIX `sh`, using the same `deb-systemd-helper` and `deb-systemd-invoke` snippets that `dh_installsystemd` generates. Each script branches on the dpkg action argument.

- **postinstall** (`configure`): `systemd-sysusers` and `systemd-tmpfiles --create` for the package's files, `systemctl daemon-reload`. First install: enable and start. Upgrade or reinstall: restart. A service the admin disabled stays disabled and stopped.
- **preremove** (`remove`): stop. Does nothing on `upgrade`.
- **postremove**: `daemon-reload`. On `remove`, mask the unit while keeping its enablement state, so a later reinstall comes back enabled. On `purge`, drop that state and delete `/var/lib/node-exporter` and `/run/node-exporter`. The system user and groups stay, per Debian convention.

As in `dh_installsystemd` output, a failure to start the service does not fail the dpkg transaction.

Scripts tolerate hosts where systemd is not running (containers, chroots): `systemctl` and service start/stop calls are skipped when `/run/systemd/system` is absent.

### Smoke test

The `test` image contains systemd, `curl`, the built `.deb`, `versions.env`, the smoke script and a oneshot unit enabled at boot. Running the container boots systemd; the unit runs the script; the container exits with the script's exit code (`SuccessAction=exit` / `FailureAction=exit`).

The script installs the package with `dpkg -i` on the live system, as on a real host, then checks:

1. the service is enabled;
2. `/metrics` answers and `node_exporter_build_info` reports the pinned upstream version;
3. a metric written to each of the two textfile directories is served.

Each check prints a line when it passes as well as when it fails, so a log shows how far a run got.

Line endings are forced to LF only for the files that are executed or parsed on Linux: shell scripts, `versions.env`, and everything under `packaging/` and `test/`.

Debian's container images ship a `policy-rc.d` that forbids starting services during package installation. The `test` image removes it so that the install behaves as it would on a real host.

### Workflow (`.github/workflows/build.yml`)

Triggers: push to `master`, pull requests, and tags matching `v*`.

**`build` job** — matrix:

| Arch | Runner |
|---|---|
| amd64 | `ubuntu-latest` |
| arm64 | `ubuntu-24.04-arm` |

Steps: check out, run the harness commands, upload the `.deb` as a workflow artifact.

**`release` job** — runs for tags only, needs `build`: fail unless the tag equals `v${NODE_EXPORTER_VERSION}-${PACKAGE_REVISION}` from `versions.env`; then create the GitHub Release with the two `.deb` files and a `SHA256SUMS`.

Workflow-level permissions are `contents: read`; only `release` gets `contents: write`. Third-party actions are pinned by commit SHA. Both jobs have a timeout.

## Versioning

The Debian version is `<upstream>-<revision>` (`1.12.1-1`) and the release tag is the same with a `v` prefix.

A pre-release flow (manual workflow run, `~`-suffixed versions, GitHub pre-releases) was implemented and then removed: it complicated the build, the workflow and the versioning rules beyond its usefulness. The `.deb` artifact of a pull request's workflow run can be downloaded and installed when a build needs trying on a host.

## Error handling

| Failure | Behaviour |
|---|---|
| Tarball hash mismatch | `build.sh` aborts before nFPM runs; the image build fails |
| Download failure | `curl --fail` aborts the script |
| Unknown architecture | `build.sh` exits non-zero with usage |
| Tag does not match `versions.env` | `release` job fails; nothing is published |
| Smoke test failure or hang | Container exits non-zero (the unit has a start timeout); `build` job fails; `release` does not run |
| Service fails to start in postinstall | Install completes (Debian convention); the smoke test catches it |

## Testing

The smoke test above is the whole test suite, deliberately. It answers one question: would this package give a working exporter on a fresh host?

Not tested, by decision: conffile preservation on upgrade, enable/disable state across upgrades, remove-then-reinstall, purge cleanliness, directory permissions, `/run` recreation at boot, and `build.sh` input rejection. These are behaviours of dpkg, `deb-systemd-helper` and `systemd-tmpfiles`, or follow directly from one line of configuration; a test for them would mostly test those tools.

## Release procedure

1. Edit `versions.env`: new upstream version and hashes with revision `1`, or bump the revision for a packaging-only change.
2. Merge to `master`; the build must be green.
3. Tag the merge commit `v<version>-<revision>` and push the tag.

## `CLAUDE.md`

A short file for future agent sessions and contributors. It records the reasons behind the choices in this document and the constraints that are not visible in the code: containers only, pin and verify everything, minimal test scope, Debian conventions over invention. It names no files and no line numbers, so it does not go stale when the code moves; the code explains how.

## Out of scope

- **Migration from v1.** The package name is unchanged, so `dpkg` upgrades in place and removes v1's files. `ARGS` set in `/etc/node-exporter/node-exporter.conf` are dropped, and textfile writers must be pointed at the new directories. Both are handled by hand per host.
- apt repository and package signing.
- Automatic tracking of upstream releases.
- Pre-releases (see Versioning).
- Other architectures (armhf and beyond) and other package formats (rpm, apk).

# nFPM packaging pipeline (v2) — design

Date: 2026-10-05

## Goal

Build a Debian package of the upstream [Prometheus node_exporter](https://github.com/prometheus/node_exporter) binary with [nFPM](https://nfpm.goreleaser.com/), in GitHub Actions, and publish it as GitHub Release assets.

The package has one consumer (the repo owner). The repo is public.

Version 1 of this repo (`make-deb.ps1` plus a `deb/` tree built with `dpkg-deb`) is a throw-away. It serves only as a checklist of what the package must do. Nothing in it constrains this design.

## Success criteria

- Pushing a tag `v<upstream>-<revision>` produces a GitHub Release with one `.deb` per architecture and a `SHA256SUMS` file.
- `dpkg -i` of that `.deb` on a clean Debian or Ubuntu host yields a running, enabled `node-exporter` service answering on port 9100.
- A `.prom` file dropped into either textfile directory shows up in `/metrics`.
- A package upgrade keeps local edits to `/etc/default/node-exporter`.
- The same build runs locally with one command.

## Decisions

| Topic | Decision |
|---|---|
| Where it builds | GitHub Actions |
| Distribution | GitHub Release assets, installed with `dpkg -i` |
| Architectures | amd64 and arm64 |
| Package name | `node-exporter` |
| Layout | FHS; follow Debian conventions throughout |
| Binary path | `/usr/bin/node-exporter` (dash, renamed from upstream's `node_exporter`) |
| Textfile collector | Two directories, persistent and volatile, both read by default |
| Version pinning | Upstream version, package revision and per-arch SHA256 committed to the repo |
| Release trigger | Git tag; must match the pinned version |
| Build logic | One bash script plus one `nfpm.yaml`, shared by CI and local builds |

## Repo layout

```
versions.env                      upstream version, package revision, SHA256 per arch
build.sh <arch>                   download, verify, extract, run nFPM into dist/
nfpm.yaml                         package definition; version and arch come from the environment
packaging/
  node-exporter.service
  node-exporter.default           installed as /etc/default/node-exporter
  node-exporter.sysusers          installed as /usr/lib/sysusers.d/node-exporter.conf
  node-exporter.tmpfiles          installed as /usr/lib/tmpfiles.d/node-exporter.conf
  scripts/
    postinstall.sh
    preremove.sh
    postremove.sh
test/
  smoke.sh <deb>                  install-and-verify test; needs root on a systemd host
  build-rejects.sh                build.sh refuses a bad arch and a wrong hash
.github/workflows/build.yml
.gitattributes                    LF line endings for everything
```

`make-deb.ps1` and `deb/` are retired. `.gitignore` covers `dist/` and `.worktrees/`.

## Components

### `versions.env`

Plain `KEY=value` lines, sourceable by bash and readable by the workflow:

- `NODE_EXPORTER_VERSION` — upstream version, for example `1.9.1`
- `PACKAGE_REVISION` — Debian revision, starts at `1`, reset to `1` on every upstream bump
- `NODE_EXPORTER_SHA256_AMD64`, `NODE_EXPORTER_SHA256_ARM64` — SHA256 of the upstream `linux-<arch>` tarballs

The pinned upstream version is the latest stable release at implementation time. Hashes come from upstream's `sha256sums.txt` and are confirmed against the downloaded tarballs.

### `build.sh <arch>`

Input: one of `amd64`, `arm64`. Output: `dist/node-exporter_<version>-<revision>_<arch>.deb`.

1. Source `versions.env` (or the file named by `VERSIONS_FILE`, which exists so the hash check can be tested).
2. Download `node_exporter-<version>.linux-<arch>.tar.gz` from the upstream GitHub release into `dist/staging/`, which is recreated on every run.
3. Verify the SHA256 against the pinned value. Abort on mismatch.
4. Extract the tarball.
5. Run `nfpm package --packager deb` with version, revision, architecture and the extracted directory passed through the environment.

The script runs with `set -euo pipefail`, rejects unknown architectures, and requires `nfpm`, `curl`, `tar` and `sha256sum` on `PATH`. It does not install nFPM itself.

### `nfpm.yaml`

One file for both architectures. Version, release and arch are expanded from environment variables set by `build.sh`.

Metadata: name `node-exporter`, section `net`, priority `optional`, maintainer, homepage (upstream), license `Apache-2.0`, `conflicts: prometheus-node-exporter`.

Every entry in `contents` sets owner and mode explicitly so that a build on Windows produces the same package as one on Linux.

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

POSIX `sh`, using the same `deb-systemd-helper` and `deb-systemd-invoke` snippets that `dh_installsystemd` generates. Each script branches on the dpkg action argument. The package therefore depends on `systemd` and `init-system-helpers`.

- **postinstall** (`configure`): `systemd-sysusers` and `systemd-tmpfiles --create` for the package's files, `systemctl daemon-reload`. First install: enable and start. Upgrade or reinstall: restart. A service the admin disabled stays disabled and stopped.
- **preremove** (`remove`): stop. Does nothing on `upgrade`.
- **postremove**: `daemon-reload`. On `remove`, mask the unit while keeping its enablement state, so a later reinstall comes back enabled. On `purge`, drop that state and delete `/var/lib/node-exporter` and `/run/node-exporter`. The system user and groups stay, per Debian convention.

As in `dh_installsystemd` output, a failure to start the service does not fail the dpkg transaction.

Scripts tolerate hosts where systemd is not running (containers, chroots): `systemctl` and service start/stop calls are skipped when `/run/systemd/system` is absent.

### Workflow (`.github/workflows/build.yml`)

Triggers: push to `master`, pull requests, tags matching `v*`.

**`build` job** — matrix:

| Arch | Runner |
|---|---|
| amd64 | `ubuntu-latest` |
| arm64 | `ubuntu-24.04-arm` |

Steps:

1. Check out.
2. Install nFPM at a pinned version, verified against a pinned SHA256.
3. `./build.sh <arch>`.
4. Smoke test on the native runner (see Testing).
5. Upload the `.deb` as a workflow artifact.

**`release` job** — tags only, needs `build`:

1. Fail unless the tag equals `v${NODE_EXPORTER_VERSION}-${PACKAGE_REVISION}` from `versions.env`.
2. Download both artifacts, generate `SHA256SUMS`.
3. Create the GitHub Release with the three files attached.

Workflow-level permissions are `contents: read`; only `release` gets `contents: write`. Third-party actions are pinned by commit SHA.

## Error handling

| Failure | Behaviour |
|---|---|
| Tarball hash mismatch | `build.sh` aborts before nFPM runs |
| Download failure | `curl --fail` aborts the script |
| Unknown architecture argument | `build.sh` exits non-zero with usage |
| Tag does not match `versions.env` | `release` job fails; nothing is published |
| Smoke test failure | `build` job fails; `release` does not run |
| Service fails to start in postinstall | Install completes (Debian convention); the smoke test's `is-active` check catches it in CI |

## Testing

The smoke test in the `build` job is the test suite. On each native runner it:

1. Inspects the package (`dpkg-deb --info`, `--contents`) and asserts name, version and architecture.
2. Installs it with `dpkg -i`.
3. Asserts `systemctl is-active` and `is-enabled`.
4. Fetches `http://localhost:9100/metrics` and asserts `node_exporter_build_info` reports the pinned version.
5. Writes a `.prom` file into each textfile directory and asserts both metrics are served.
6. Edits `/etc/default/node-exporter`, reinstalls the package, and asserts the edit survived.
7. Purges, then asserts the unit and `/var/lib/node-exporter` are gone.

The test lives in its own script so it can be run by hand on a disposable host.

## Release procedure

1. Edit `versions.env`: new upstream version and hashes with revision `1`, or bump the revision for a packaging-only change.
2. Merge to `master`; the build must be green.
3. Tag the merge commit `v<version>-<revision>` and push the tag.

## Out of scope

- **Migration from v1.** The package name is unchanged, so `dpkg` upgrades in place and removes v1's files. `ARGS` set in `/etc/node-exporter/node-exporter.conf` are dropped, and textfile writers must be pointed at the new directories. Both are handled by hand per host.
- apt repository and package signing.
- Automatic tracking of upstream releases.
- Other architectures (armhf and beyond) and other package formats (rpm, apk).

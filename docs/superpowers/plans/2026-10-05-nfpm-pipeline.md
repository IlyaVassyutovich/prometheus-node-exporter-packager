# nFPM Packaging Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `node-exporter` Debian package for amd64 and arm64 from the upstream node_exporter release binary with nFPM, entirely in containers, and publish it to GitHub Releases: a final release on a version tag, a pre-release on a manual workflow run.

**Architecture:** `versions.env` pins the upstream version, package revision and tarball hashes. A three-stage `Containerfile` builds the package (`build`), exposes it for export (`package`) and boots a systemd Debian container that installs it and runs a short smoke script (`test`). Three container commands are the whole harness, the same locally and in GitHub Actions.

**Tech Stack:** nFPM 2.47.0 (from its official image), Docker or Podman, Debian 13 slim, bash (build script), POSIX sh (maintainer scripts, smoke script), systemd (`sysusers.d`, `tmpfiles.d`, `deb-systemd-helper`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-05-nfpm-pipeline-design.md`

## Global Constraints

- Work only in the worktree `.worktrees/feature/nfpm-pipeline` (branch `feature/nfpm-pipeline`). The shell's working directory can reset to the main checkout between commands, so run every command from the worktree explicitly and never write in the main checkout.
- Nothing may be required on the host except a container engine. No host-side wrapper scripts.
- Package name `node-exporter`; service `node-exporter.service`; binary `/usr/bin/node-exporter`.
- Architectures: `amd64`, `arm64` only.
- Upstream node_exporter `1.12.1`, package revision `1`, Debian version `1.12.1-1`.
- nFPM `2.47.0` from `ghcr.io/goreleaser/nfpm`, pinned by tag and digest.
- Maintainer: `Ilya Vassyutovich <me@iv.link>`.
- Textfile directories: `/var/lib/node-exporter/textfile-collector` and `/run/node-exporter/textfile-collector`, both `root:node-exporter-textfile-writers`, mode `2775`.
- Every `contents` entry in `nfpm.yaml` sets owner, group and mode explicitly.
- All files use LF line endings. Shell scripts indent with 4 spaces, YAML with 2.
- Comments explain why, never what.
- Test scope is one minimal smoke scenario by decision. Do not add tests beyond it.
- Commits: new commits only, no `--amend`, no `Co-authored-by` trailer. Commits are GPG-signed; a commit that hangs is waiting for a passphrase prompt on the user's screen.
- Pushing the feature branch, opening a PR, running the local container harness and checking Actions are fine without asking. Merging to `master` and pushing a release tag are the user's call.
- Third-party GitHub Actions are pinned by commit SHA.
- When running `podman`/`docker` from Git Bash on Windows with a container-side absolute path as an argument, prefix the command with `MSYS_NO_PATHCONV=1`, or Git Bash rewrites the path.

## Review Focus

The spec deliberately limits testing to one smoke scenario, so the conditions below have no test and none should be added. They are the places where a reviewer reading the code is the only check, most likely to bite first:

1. `ARGS` in `/etc/default/node-exporter` with several whitespace-separated flags: the unit must pass `$ARGS` unquoted and unbraced so systemd splits it.
2. A pre-release must sort below its final release: the suffix must be joined to the revision with `~`, and nowhere with `-` or `+`.
3. The two textfile directories must be group-writable and setgid (`2775`) for the writers group and not world-writable.
4. Maintainer scripts must not fail on a host without a running systemd: every `systemctl` and `deb-systemd-invoke` call sits behind the `/run/systemd/system` check.
5. The `release` job must be unable to publish a final release from anything but a pushed tag that matches `versions.env`.

## File Structure

| File | Responsibility |
|---|---|
| `.gitattributes` | Force LF so scripts work when checked out on Windows |
| `.editorconfig` | Indentation for shell and YAML |
| `.gitignore` | Ignore `dist/`, `.worktrees/` |
| `.dockerignore` | Keep the build context to what the build reads |
| `versions.env` | The only place versions and hashes are pinned |
| `Containerfile` | The `build`, `package` and `test` stages |
| `build.sh` | Download, verify, extract, invoke nFPM (inside `build`) |
| `nfpm.yaml` | Package metadata and file mapping |
| `packaging/node-exporter.service` | systemd unit |
| `packaging/node-exporter.default` | Default `/etc/default/node-exporter` |
| `packaging/node-exporter.sysusers` | User and group declarations |
| `packaging/node-exporter.tmpfiles` | Textfile directory declarations |
| `packaging/scripts/postinstall.sh` | Create users and directories, enable, start or restart |
| `packaging/scripts/preremove.sh` | Stop on removal |
| `packaging/scripts/postremove.sh` | Mask on removal, clean up on purge |
| `test/smoke.sh` | The smoke scenario (inside `test`) |
| `test/smoke.service` | Runs the scenario at boot; its result is the container's exit code |
| `.github/workflows/build.yml` | CI build, test, release and pre-release |
| `README.md`, `ROADMAP.md` | Usage, release procedure, future ideas |
| `CLAUDE.md` | Why the repo is built this way |

---

### Task 1: Repository hygiene and v1 removal

**Files:**
- Create: `.gitattributes`, `.dockerignore`
- Modify: `.editorconfig`, `.gitignore`
- Delete: `make-deb.ps1`, `deb/`

**Interfaces:**
- Consumes: nothing.
- Produces: LF checkout for all later files; a build context without `.git`, `dist/`, `docs/`.

- [ ] **Step 1: Create `.gitattributes`**

```gitattributes
# Everything here ends up running on Linux; a CRLF checkout on Windows would
# put "\r" into shell scripts and unit files and break them.
* text=auto eol=lf
```

- [ ] **Step 2: Replace `.editorconfig`**

```ini
root = true

[*]
end_of_line = lf
insert_final_newline = true

[*.sh]
indent_style = space
indent_size = 4

[*.{yaml,yml}]
indent_style = space
indent_size = 2
```

- [ ] **Step 3: Replace `.gitignore`**

```gitignore
dist/
.worktrees/
```

- [ ] **Step 4: Create `.dockerignore`**

Podman reads this file too.

```
.git
.github
.worktrees
dist
docs
*.md
```

- [ ] **Step 5: Remove the v1 files**

They are fully in git history, so a plain removal is safe.

```bash
git rm -r --quiet make-deb.ps1 deb
```

- [ ] **Step 6: Verify**

Run: `git add -A && git add --renormalize . && git status --short`
Expected: `A` for `.gitattributes` and `.dockerignore`, `M` for `.editorconfig` and `.gitignore`, `D` for `make-deb.ps1` and every file under `deb/`.

- [ ] **Step 7: Commit**

```bash
git commit -m "Remove v1 packaging and enforce LF line endings"
```

---

### Task 2: Package payload

**Files:**
- Create: `packaging/node-exporter.service`, `packaging/node-exporter.default`, `packaging/node-exporter.sysusers`, `packaging/node-exporter.tmpfiles`, `packaging/scripts/postinstall.sh`, `packaging/scripts/preremove.sh`, `packaging/scripts/postremove.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the seven files above at exactly these paths, referenced by `nfpm.yaml` in Task 3. Installed names: `/usr/lib/systemd/system/node-exporter.service`, `/etc/default/node-exporter`, `/usr/lib/sysusers.d/node-exporter.conf`, `/usr/lib/tmpfiles.d/node-exporter.conf`.

- [ ] **Step 1: Create `packaging/node-exporter.service`**

```ini
[Unit]
Description=Prometheus exporter for machine metrics
Documentation=https://github.com/prometheus/node_exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node-exporter
Group=node-exporter
EnvironmentFile=-/etc/default/node-exporter
ExecStart=/usr/bin/node-exporter \
    --collector.textfile.directory=/var/lib/node-exporter/textfile-collector \
    --collector.textfile.directory=/run/node-exporter/textfile-collector \
    $ARGS
Restart=on-failure
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

There is deliberately no `ExecReload` and no sandboxing beyond `NoNewPrivileges`; the spec explains both.

- [ ] **Step 2: Create `packaging/node-exporter.default`**

```sh
# Extra command-line arguments for node-exporter, split on whitespace.
# Run `node-exporter --help` for the available options.
#
# The two packaged textfile directories are always passed by the unit:
#   /var/lib/node-exporter/textfile-collector   kept across reboots
#   /run/node-exporter/textfile-collector       emptied on reboot
ARGS=""
```

- [ ] **Step 3: Create `packaging/node-exporter.sysusers`**

```
#Type Name                           ID GECOS
u     node-exporter                  -  "Prometheus node exporter"
g     node-exporter-textfile-writers -
```

- [ ] **Step 4: Create `packaging/node-exporter.tmpfiles`**

```
#Type Path                                      Mode UID  GID
d     /var/lib/node-exporter                    0755 root root
d     /var/lib/node-exporter/textfile-collector 2775 root node-exporter-textfile-writers
d     /run/node-exporter                        0755 root root
d     /run/node-exporter/textfile-collector     2775 root node-exporter-textfile-writers
```

- [ ] **Step 5: Create `packaging/scripts/postinstall.sh`**

```sh
#!/bin/sh
set -e

SERVICE=node-exporter.service

if [ "$1" = "configure" ] || [ "$1" = "abort-upgrade" ] || [ "$1" = "abort-deconfigure" ] || [ "$1" = "abort-remove" ]; then
    systemd-sysusers /usr/lib/sysusers.d/node-exporter.conf
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/node-exporter.conf

    # postremove masks the unit on removal; a reinstall has to lift that.
    deb-systemd-helper unmask "$SERVICE" >/dev/null || true
    # was-enabled is true on first install and false once the admin has
    # disabled the unit, so their choice survives upgrades.
    if deb-systemd-helper --quiet was-enabled "$SERVICE"; then
        deb-systemd-helper enable "$SERVICE" >/dev/null || true
    else
        deb-systemd-helper update-state "$SERVICE" >/dev/null || true
    fi

    # Absent in containers and chroots, where there is no manager to talk to.
    if [ -d /run/systemd/system ]; then
        systemctl --system daemon-reload >/dev/null || true
        if [ -n "$2" ]; then
            action=restart
        else
            action=start
        fi
        # A unit that is both disabled and stopped was switched off on
        # purpose; leave it alone. One that is disabled but running still
        # needs the restart to pick up the new binary.
        if systemctl is-enabled --quiet "$SERVICE" || systemctl is-active --quiet "$SERVICE"; then
            deb-systemd-invoke "$action" "$SERVICE" >/dev/null || true
        fi
    fi
fi
```

- [ ] **Step 6: Create `packaging/scripts/preremove.sh`**

```sh
#!/bin/sh
set -e

# Only on removal: during an upgrade the old process keeps serving until
# postinstall restarts it, which avoids a gap in metrics.
if [ "$1" = "remove" ] && [ -d /run/systemd/system ]; then
    deb-systemd-invoke stop node-exporter.service >/dev/null || true
fi
```

- [ ] **Step 7: Create `packaging/scripts/postremove.sh`**

```sh
#!/bin/sh
set -e

SERVICE=node-exporter.service

if [ "$1" = "remove" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl --system daemon-reload >/dev/null || true
    fi
    # Masking, rather than disabling, keeps the recorded enablement so a
    # reinstall comes back the way the admin left it.
    if [ -x /usr/bin/deb-systemd-helper ]; then
        deb-systemd-helper mask "$SERVICE" >/dev/null || true
    fi
fi

if [ "$1" = "purge" ]; then
    if [ -x /usr/bin/deb-systemd-helper ]; then
        deb-systemd-helper purge "$SERVICE" >/dev/null || true
        deb-systemd-helper unmask "$SERVICE" >/dev/null || true
    fi
    # The user and groups are kept on purpose: files written by textfile
    # jobs may still be owned by them, and Debian policy advises against
    # recycling system UIDs.
    rm -rf /var/lib/node-exporter /run/node-exporter
fi
```

- [ ] **Step 8: Check syntax**

Run: `for f in packaging/scripts/*.sh; do sh -n "$f" || echo "BAD $f"; done; echo done`
Expected: `done` with no `BAD` lines.

- [ ] **Step 9: Commit**

```bash
git add packaging
git commit -m "Add package payload: unit, defaults, sysusers, tmpfiles, maintainer scripts"
```

---

### Task 3: Containerised build

**Files:**
- Create: `versions.env`, `nfpm.yaml`, `build.sh`, `Containerfile` (stages `nfpm`, `build`, `package`)

**Interfaces:**
- Consumes: the `packaging/` files from Task 2.
- Produces:
  - `versions.env` with `NODE_EXPORTER_VERSION`, `PACKAGE_REVISION`, `NODE_EXPORTER_SHA256_AMD64`, `NODE_EXPORTER_SHA256_ARM64`.
  - Containerfile stage `package` whose root holds exactly one `node-exporter_<version>-<revision>_<arch>.deb`.
  - Build argument `PRERELEASE` (default empty); when set, the Debian revision becomes `<revision>~<PRERELEASE>`.
  - Harness command: `<engine> build --target package --output dist .`

- [ ] **Step 1: Create `versions.env`**

The hashes are the SHA256 digests GitHub reports for the two release assets of node_exporter v1.12.1.

```sh
# Upstream node_exporter release to package.
NODE_EXPORTER_VERSION=1.12.1
# Debian revision. Reset to 1 whenever NODE_EXPORTER_VERSION changes.
PACKAGE_REVISION=1
# SHA256 of node_exporter-<version>.linux-<arch>.tar.gz
NODE_EXPORTER_SHA256_AMD64=b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63
NODE_EXPORTER_SHA256_ARM64=ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7
```

- [ ] **Step 2: Create `nfpm.yaml`**

```yaml
name: node-exporter
arch: ${PACKAGE_ARCH}
platform: linux
version: ${PACKAGE_VERSION}
release: ${PACKAGE_REVISION}
section: net
priority: optional
maintainer: Ilya Vassyutovich <me@iv.link>
description: |
  Prometheus exporter for machine metrics
  Upstream node_exporter release binary, repackaged with a systemd unit,
  a dedicated system user and two textfile collector directories.
homepage: https://github.com/prometheus/node_exporter
license: Apache-2.0

depends:
  - systemd
  - init-system-helpers
conflicts:
  # Debian's own package listens on the same port.
  - prometheus-node-exporter

# Modes and owners are spelled out on every entry so the package never
# inherits whatever modes the build context happened to have; a checkout on
# Windows has none worth trusting.
contents:
  - src: dist/staging/upstream/node_exporter
    dst: /usr/bin/node-exporter
    file_info:
      mode: 0755
      owner: root
      group: root
  - src: packaging/node-exporter.service
    dst: /usr/lib/systemd/system/node-exporter.service
    file_info:
      mode: 0644
      owner: root
      group: root
  - src: packaging/node-exporter.default
    dst: /etc/default/node-exporter
    type: config|noreplace
    file_info:
      mode: 0644
      owner: root
      group: root
  - src: packaging/node-exporter.sysusers
    dst: /usr/lib/sysusers.d/node-exporter.conf
    file_info:
      mode: 0644
      owner: root
      group: root
  - src: packaging/node-exporter.tmpfiles
    dst: /usr/lib/tmpfiles.d/node-exporter.conf
    file_info:
      mode: 0644
      owner: root
      group: root
  - src: dist/staging/upstream/LICENSE
    dst: /usr/share/doc/node-exporter/LICENSE
    file_info:
      mode: 0644
      owner: root
      group: root
  - src: dist/staging/upstream/NOTICE
    dst: /usr/share/doc/node-exporter/NOTICE
    file_info:
      mode: 0644
      owner: root
      group: root

scripts:
  postinstall: packaging/scripts/postinstall.sh
  preremove: packaging/scripts/preremove.sh
  postremove: packaging/scripts/postremove.sh
```

- [ ] **Step 3: Create `build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 <amd64|arm64>" >&2
    exit 2
}

[ $# -eq 1 ] || usage
ARCH=$1

cd "$(dirname "$0")"
. ./versions.env

case "$ARCH" in
    amd64) EXPECTED_SHA256=$NODE_EXPORTER_SHA256_AMD64 ;;
    arm64) EXPECTED_SHA256=$NODE_EXPORTER_SHA256_ARM64 ;;
    *) usage ;;
esac

TARBALL_NAME="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL_NAME}"
STAGING=dist/staging
TARBALL="$STAGING/upstream.tar.gz"

mkdir -p "$STAGING/upstream"

curl --fail --silent --show-error --location --output "$TARBALL" "$URL"
echo "Downloaded $TARBALL_NAME"

echo "${EXPECTED_SHA256}  ${TARBALL}" | sha256sum --check --strict --quiet
echo "Verified SHA256"

tar --extract --gzip --file "$TARBALL" --directory "$STAGING/upstream" --strip-components 1

export PACKAGE_ARCH=$ARCH
export PACKAGE_VERSION=$NODE_EXPORTER_VERSION
# "~" sorts before everything in Debian version ordering, even the end of
# the string, so a pre-release is always older than the release it precedes.
export PACKAGE_REVISION="${PACKAGE_REVISION}${PRERELEASE:+~${PRERELEASE}}"
nfpm package --config nfpm.yaml --packager deb --target dist/
```

- [ ] **Step 4: Create `Containerfile`**

```dockerfile
# nFPM's own image is the pinned source of the binary. The digest is the
# multi-architecture index, so it resolves on amd64 and arm64 alike.
FROM --platform=$BUILDPLATFORM ghcr.io/goreleaser/nfpm:v2.47.0@sha256:74f890d72b1198cab1535b1d73edac3edb91fd6a63c63014d0dac5c766ab6211 AS nfpm

# Packaging only downloads and repacks, so this stage runs on the build
# machine's own platform and takes the target architecture as a plain value.
# An arm64 package can be built on amd64 without emulation.
FROM --platform=$BUILDPLATFORM debian:13-slim AS build
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=nfpm /usr/bin/nfpm /usr/bin/nfpm
WORKDIR /src
COPY versions.env nfpm.yaml build.sh ./
COPY packaging/ packaging/
ARG TARGETARCH
ARG PRERELEASE=""
# Invoked through bash so the result does not depend on the executable bit,
# which a Windows checkout does not carry into the build context.
RUN PRERELEASE="$PRERELEASE" bash build.sh "$TARGETARCH"

# Nothing but the package, so `--output` exports exactly one file.
FROM scratch AS package
COPY --from=build /src/dist/*.deb /
```

- [ ] **Step 5: Confirm the nFPM digest is the multi-arch index**

Run: `podman manifest inspect ghcr.io/goreleaser/nfpm:v2.47.0@sha256:74f890d72b1198cab1535b1d73edac3edb91fd6a63c63014d0dac5c766ab6211`
Expected: an image index whose `manifests` list includes `linux/amd64` and `linux/arm64`. If the command reports a single-platform manifest instead, replace the digest in `Containerfile` with the index digest printed by `podman manifest inspect ghcr.io/goreleaser/nfpm:v2.47.0 --verbose` (or `docker buildx imagetools inspect ghcr.io/goreleaser/nfpm:v2.47.0`).

- [ ] **Step 6: Build the package**

Run: `podman build --target package --output dist .`
Expected: exit 0, log lines `Downloaded node_exporter-1.12.1.linux-amd64.tar.gz` and `Verified SHA256`, and `ls dist` shows `node-exporter_1.12.1-1_amd64.deb`.

- [ ] **Step 7: Build a pre-release variant and the other architecture**

Run: `podman build --platform linux/arm64 --build-arg PRERELEASE=pre7.abc1234 --target package --output dist .`
Expected: `ls dist` additionally shows `node-exporter_1.12.1-1~pre7.abc1234_arm64.deb`. This proves the architecture is taken from the target platform, that the arm64 hash is right, and that nFPM accepts the pre-release revision.

- [ ] **Step 8: Commit**

```bash
git add versions.env nfpm.yaml build.sh Containerfile
git commit -m "Add containerised nFPM build with pinned versions"
```

---

### Task 4: Smoke test stage

**Files:**
- Create: `test/smoke.sh`, `test/smoke.service`
- Modify: `Containerfile` (append the `test` stage)

**Interfaces:**
- Consumes: Containerfile stage `package`; `versions.env` (`NODE_EXPORTER_VERSION`).
- Produces: harness commands `<engine> build --target test --tag node-exporter-smoke .` and `<engine> run --rm --tty --privileged node-exporter-smoke`; the run exits 0 and prints `SMOKE PASS` on success, exits non-zero and prints `SMOKE FAIL: <reason>` otherwise.

- [ ] **Step 1: Create `test/smoke.sh`**

```sh
#!/bin/sh
set -eu

fail() {
    echo "SMOKE FAIL: $*"
    exit 1
}

# Installed on the running system rather than while building the image,
# because that is the path a real host takes: postinstall has to create the
# user and directories and start the service itself.
dpkg --install /smoke/*.deb

systemctl is-enabled --quiet node-exporter.service || fail "service is not enabled"

echo 'smoke_persistent 1' >/var/lib/node-exporter/textfile-collector/smoke.prom
echo 'smoke_volatile 1' >/run/node-exporter/textfile-collector/smoke.prom

# The listener needs a moment after the unit has been started.
metrics=$(curl --fail --silent --show-error \
    --retry 10 --retry-delay 1 --retry-connrefused \
    http://localhost:9100/metrics) || fail "no answer on port 9100"

serves() { printf '%s\n' "$metrics" | grep -q "$1"; }

serves "^node_exporter_build_info{.*version=\"${NODE_EXPORTER_VERSION}\"" \
    || fail "exporter does not report version ${NODE_EXPORTER_VERSION}"
serves '^smoke_persistent 1$' || fail "metric from the persistent textfile directory is not served"
serves '^smoke_volatile 1$' || fail "metric from the volatile textfile directory is not served"

echo "SMOKE PASS: node-exporter ${NODE_EXPORTER_VERSION} installs, runs and reads both textfile directories"
```

- [ ] **Step 2: Create `test/smoke.service`**

```ini
[Unit]
Description=node-exporter package smoke test
# The container exists only to run this unit, so the unit's result becomes
# the container's exit code.
SuccessAction=exit
FailureAction=exit

[Service]
Type=oneshot
EnvironmentFile=/smoke/versions.env
ExecStart=/bin/sh /smoke/smoke.sh
# The journal dies with the container; the console is what `run` shows.
StandardOutput=journal+console
StandardError=journal+console
# A hang must end the container with a failure instead of blocking CI.
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Append the `test` stage to `Containerfile`**

```dockerfile

FROM debian:13-slim AS test
# Debian's container images ship a policy-rc.d that forbids starting
# services during package installation. A real host has none, and the smoke
# test is about what happens on a real host.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends systemd init-system-helpers curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d
COPY --from=package / /smoke/
COPY versions.env test/smoke.sh /smoke/
COPY test/smoke.service /etc/systemd/system/smoke.service
RUN systemctl enable smoke.service
# Boot status lines would bury the test's own output.
CMD ["/usr/lib/systemd/systemd", "--show-status=false"]
```

- [ ] **Step 4: Run the harness**

Run:
```bash
podman build --target test --tag node-exporter-smoke .
podman run --rm --tty --privileged node-exporter-smoke; echo "exit=$?"
```
Expected: the output contains `SMOKE PASS: node-exporter 1.12.1 installs, runs and reads both textfile directories` and ends with `exit=0`. `--tty` is required: without a terminal systemd writes nothing to the container's output. Some unrelated systemd log lines (failed kernel-module loading, `sys-kernel-config.mount`) are normal in a container.

- [ ] **Step 5: Fix what the smoke test finds**

This is the first time the package is installed anywhere, so a `SMOKE FAIL` here is the test doing its job. Find the root cause in the owning file (unit, maintainer script, tmpfiles, `nfpm.yaml`), fix it there, and rerun Step 4. For more detail, start the same image with a shell instead of the default command and inspect it by hand:

```bash
MSYS_NO_PATHCONV=1 podman run --rm --interactive --tty --privileged node-exporter-smoke /bin/bash
```

Do not weaken a check to get a pass. If a check turns out to describe wrong behaviour, stop and raise it with the user.

- [ ] **Step 6: Commit**

```bash
git add Containerfile test
git commit -m "Add smoke test stage that installs the package under systemd"
```

---

### Task 5: GitHub Actions workflow and first CI run

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: the three harness commands; build argument `PRERELEASE`; `versions.env`.
- Produces: artifacts `deb-amd64` and `deb-arm64`; a GitHub Release on a matching tag; a GitHub pre-release on a manual run.

- [ ] **Step 1: Create `.github/workflows/build.yml`**

```yaml
name: build

on:
  push:
    branches: [master]
    tags: ["v*"]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
          - arch: arm64
            runner: ubuntu-24.04-arm
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Derive pre-release id
        if: github.event_name == 'workflow_dispatch'
        run: echo "PRERELEASE=pre${GITHUB_RUN_NUMBER}.${GITHUB_SHA::7}" >>"$GITHUB_ENV"

      - name: Build package
        run: docker build --build-arg "PRERELEASE=${PRERELEASE:-}" --target package --output dist .

      - name: Build test image
        run: docker build --build-arg "PRERELEASE=${PRERELEASE:-}" --target test --tag node-exporter-smoke .

      - name: Smoke test
        run: docker run --rm --tty --privileged node-exporter-smoke

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: deb-${{ matrix.arch }}
          path: dist/*.deb
          if-no-files-found: error

  release:
    if: startsWith(github.ref, 'refs/tags/v') || github.event_name == 'workflow_dispatch'
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Release tag must match versions.env
        if: github.event_name == 'push'
        run: |
          . ./versions.env
          expected="v${NODE_EXPORTER_VERSION}-${PACKAGE_REVISION}"
          if [ "$GITHUB_REF_NAME" != "$expected" ]; then
            echo "::error::tag $GITHUB_REF_NAME does not match versions.env ($expected)"
            exit 1
          fi

      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          pattern: deb-*
          path: dist
          merge-multiple: true

      - name: Generate checksums
        working-directory: dist
        run: |
          # GitHub rewrites "~" in asset names on upload. Renaming first keeps
          # the names in SHA256SUMS equal to the names people download.
          for file in *.deb; do
            renamed=${file//\~/.}
            if [ "$file" != "$renamed" ]; then mv -- "$file" "$renamed"; fi
          done
          sha256sum -- *.deb >SHA256SUMS

      - name: Publish release
        if: github.event_name == 'push'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/*.deb dist/SHA256SUMS \
            --verify-tag --title "$GITHUB_REF_NAME" --generate-notes

      - name: Publish pre-release
        if: github.event_name == 'workflow_dispatch'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          . ./versions.env
          tag="v${NODE_EXPORTER_VERSION}-${PACKAGE_REVISION}-pre${GITHUB_RUN_NUMBER}.${GITHUB_SHA::7}"
          gh release create "$tag" dist/*.deb dist/SHA256SUMS \
            --prerelease --target "$GITHUB_SHA" --title "$tag" \
            --notes "Pre-release built from \`${GITHUB_REF_NAME}\` at ${GITHUB_SHA}."
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add build, test, release and pre-release workflow"
```

- [ ] **Step 3: Push and open a draft pull request**

The workflow triggers on pull requests, so a PR is what makes CI run on this branch.

```bash
git push origin feature/nfpm-pipeline
gh pr create --draft --base master --head feature/nfpm-pipeline \
  --title "Package node-exporter with nFPM" \
  --body "Replaces the v1 dpkg-deb script with a containerised nFPM pipeline. Spec: docs/superpowers/specs/2026-10-05-nfpm-pipeline-design.md"
```

- [ ] **Step 4: Watch the run**

Run: `gh pr checks --watch`
Expected: `build (amd64)` and `build (arm64)` pass; `release` is skipped.

- [ ] **Step 5: Fix what CI finds**

The local run used Podman on amd64; CI is the first run on Docker and the first on arm64, so differences surface here. Read the failing step with `gh run view --log-failed`, fix the root cause, commit each fix separately with a message naming the cause, push, and repeat Step 4 until both jobs pass. If systemd fails to boot under Docker (the container exits at once with a cgroup error), add `--cgroupns=host` to the `docker run` line and to the README's run command, and record the reason in a workflow comment.

The pre-release path cannot be exercised yet: GitHub only offers a manual run for workflows that exist on the default branch. It is first tried after the merge (Task 6, Step 5).

---

### Task 6: Documentation

**Files:**
- Create: `CLAUDE.md`
- Modify: `README.md`, `ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing and agent-facing documentation.

- [ ] **Step 1: Replace `README.md`**

````markdown
# Prometheus node_exporter DEB package

Packages the upstream [node_exporter](https://github.com/prometheus/node_exporter) release binary as a Debian package for amd64 and arm64, using [nFPM](https://nfpm.goreleaser.com/).

Roadmap and ideas are in [ROADMAP](./ROADMAP.md).

## Install

Download the `.deb` for your architecture from the [latest release](https://github.com/IlyaVassyutovich/prometheus-node-exporter-packager/releases/latest), check it against `SHA256SUMS`, then:

```sh
sudo dpkg -i node-exporter_*_amd64.deb
```

The service starts immediately and listens on port 9100.

## What the package sets up

| Path | Purpose |
|---|---|
| `/usr/bin/node-exporter` | The upstream binary |
| `/etc/default/node-exporter` | Extra flags in `ARGS`; kept across upgrades |
| `/var/lib/node-exporter/textfile-collector` | Textfile metrics that survive a reboot |
| `/run/node-exporter/textfile-collector` | Textfile metrics that are dropped on reboot |

The service runs as the `node-exporter` user. To let a job publish textfile metrics, add its user to the `node-exporter-textfile-writers` group and have it write `*.prom` files into either directory.

After editing `/etc/default/node-exporter`, run `sudo systemctl restart node-exporter`.

The package conflicts with Debian's `prometheus-node-exporter`.

## Build and test locally

The only requirement is Docker or Podman; the commands are the same for both.

```sh
podman build --target package --output dist .
podman build --target test --tag node-exporter-smoke .
podman run --rm --tty --privileged node-exporter-smoke
```

The first command writes the `.deb` to `dist/`. The last one boots a throw-away Debian container with systemd, installs the package in it and checks that the exporter runs; it prints `SMOKE PASS` and exits 0 on success.

Add `--platform linux/arm64` to the first command to build the other architecture. The test runs on your machine's own architecture.

## Release

1. Edit `versions.env`: set the new upstream version and both hashes with `PACKAGE_REVISION=1`, or raise `PACKAGE_REVISION` for a packaging-only change.
2. Optional: run the `build` workflow by hand on your branch (Actions tab, or `gh workflow run build --ref <branch>`). It publishes a pre-release you can try on a host; its version sorts below the final one, so the final release installs over it as a normal upgrade.
3. Merge to `master` and wait for a green build.
4. Tag the merge commit `v<version>-<revision>`, for example `v1.12.1-1`, and push the tag.

The workflow refuses to publish a release if the tag does not match `versions.env`. Pre-releases are not cleaned up automatically.

![wzrd](https://wzrd.iv.link)
````

- [ ] **Step 2: Replace `ROADMAP.md`**

```markdown
- [ ] Publish a signed apt repository so hosts update through `apt upgrade`
- [ ] Track upstream node_exporter releases automatically
- [ ] Clean up old pre-releases automatically
- [ ] Build for armhf
```

- [ ] **Step 3: Create `CLAUDE.md`**

```markdown
# Why this repo is the way it is

This repo repackages the upstream Prometheus node_exporter release binary as a Debian package. It has one consumer, its owner, but it is public. It contains no application code: its whole value is in a small number of packaging decisions. This file records the reasons for them. How things work is the code's job; if the code cannot explain itself, fix the code rather than documenting it here.

## Principles

**Repackage, never rebuild.** The binary is upstream's own release artifact. Compiling it here would add a toolchain to maintain and would make the package differ from what upstream tested.

**Pin and verify everything that is downloaded.** The upstream version and its checksums are committed, and the build fails on a mismatch. The checksums come from a commit a human reviewed, not from the place the tarball is downloaded from, so a tampered upstream release cannot slip through. The same reasoning is why build tools and CI actions are pinned by digest or commit rather than by a moving tag.

**All versions live in one place.** A version bump should be a one-file change that is easy to review.

**Containers are the only build environment.** A developer machine is assumed to have Docker or Podman and nothing else: no particular shell, no Debian tooling, no nFPM. Local runs and CI execute the same container build, so there is one code path and "works on my machine" cannot diverge from CI. This is also why there are no host-side wrapper scripts.

**Follow Debian conventions instead of inventing.** Standard paths, declarative user and directory creation, and the same service-handling snippets Debian's own tooling generates. A host admin should find nothing surprising. When in doubt, do what a package from the Debian archive would do.

**Keep the package's name and identity distinct from Debian's own node exporter package.** They would fight over the same port, so the two are declared as conflicting rather than made interchangeable. Mirroring Debian's name would let an ordinary `apt upgrade` silently replace this package.

## Decisions that look odd without context

**Two textfile directories.** One persists across reboots and one does not. Rare jobs (a nightly backup) want their last result to survive a reboot; other metrics must not be reported stale after one. Both are provisioned and read by default so a host needs no extra setup. Writing is restricted to a dedicated group so that publishing metrics does not require running as the exporter or as root.

**The service has almost no sandboxing.** The exporter's job is to observe the whole host. The usual systemd hardening options hide exactly the things it measures.

**The service cannot be reloaded.** The exporter has no reload handler; a reload signal would terminate it in a way systemd regards as a clean stop and does not restart.

**The service user is never deleted.** Files it or the writers group own may outlive the package, and reusing system account IDs is discouraged in Debian.

**A failed service start does not fail the package installation.** This is the Debian norm: a half-configured package is harder to recover from than a stopped service. The smoke test exists to catch this case before a release.

**Pre-release versions use `~`.** In Debian version ordering it sorts before everything, so every pre-release is older than the release it leads to and the final package installs over it as a normal upgrade. Never join a pre-release suffix with anything else.

## Testing

There is one smoke test, and that is deliberate. It answers a single question: does this package give a working exporter on a fresh host? It installs the package into a booted systemd container the way a real host would.

Do not grow it into a lifecycle suite. Upgrade, removal, purge and config-preservation behaviour belong to dpkg and systemd tooling; testing them here would mostly test those tools, and the test code would outweigh the thing under test. Add a check only for behaviour this repo itself implements and that has actually broken.

## Releasing

A final release is cut by a human pushing a tag, and CI refuses to publish if the tag disagrees with the pinned versions: the tag is a statement of intent, the pinned file is the truth, and they must not drift. Pre-releases are produced on demand from any branch so a change can be tried on a real host before it is merged.

## Working in this repo

- Line endings are forced to LF because everything here runs on Linux even when it is edited on Windows.
- Nothing may depend on file modes or executable bits from the checkout, for the same reason.
- Comments say why, not what.
- If a change needs a new tool on the host, it is the wrong change; put the tool in a container stage.
```

- [ ] **Step 4: Commit and push**

```bash
git add README.md ROADMAP.md CLAUDE.md
git commit -m "Document usage, release procedure and design rationale"
git push origin feature/nfpm-pipeline
```

Then run `gh pr checks --watch` and confirm both build jobs are still green.

- [ ] **Step 5: Hand over**

Mark the PR ready for review and report to the user: CI status and the PR link. Merging is the user's call. After the merge, exercise the pre-release path once with `gh workflow run build --ref master` and confirm a pre-release appears with two `.deb` files and a `SHA256SUMS`; then the user can tag `v1.12.1-1` for the first final release.

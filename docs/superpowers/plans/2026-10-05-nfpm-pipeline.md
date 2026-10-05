# nFPM Packaging Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `node-exporter` Debian package for amd64 and arm64 from the upstream node_exporter release binary with nFPM, in GitHub Actions, and publish it to a GitHub Release when a version tag is pushed.

**Architecture:** `versions.env` pins the upstream version, package revision and tarball hashes. `build.sh <arch>` downloads and verifies the tarball, then runs nFPM against one `nfpm.yaml`. `test/smoke.sh` installs the result on a systemd host and verifies it end to end. A GitHub Actions workflow runs build and smoke test per architecture on native runners and, on a tag, publishes the Release.

**Tech Stack:** nFPM 2.47.0, bash, POSIX sh (maintainer scripts), systemd (`sysusers.d`, `tmpfiles.d`, `deb-systemd-helper`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-05-nfpm-pipeline-design.md`

## Global Constraints

- Work only in the worktree `.worktrees/feature/nfpm-pipeline` (branch `feature/nfpm-pipeline`). Never write in the main checkout.
- Package name `node-exporter`; service `node-exporter.service`; binary `/usr/bin/node-exporter`.
- Architectures: `amd64`, `arm64` only.
- Upstream node_exporter `1.12.1`, package revision `1`, Debian version `1.12.1-1`.
- nFPM `2.47.0`, installed from the release tarball and verified by SHA256.
- Textfile directories: `/var/lib/node-exporter/textfile-collector` and `/run/node-exporter/textfile-collector`, both `root:node-exporter-textfile-writers`, mode `2775`.
- Config file `/etc/default/node-exporter` is a conffile (`config|noreplace`).
- Every `contents` entry in `nfpm.yaml` sets owner, group and mode explicitly.
- All files use LF line endings. Shell scripts indent with 4 spaces, YAML with 2.
- Comments explain why, never what.
- Never delete with `rm`; move to `.<name>.<timestamp>.bak` instead. (`rm` inside the shipped scripts, acting on build or package state, is fine.)
- Commits: new commits only, no `--amend`, no `Co-authored-by` trailer.
- Do not run tests, push, open a PR or create a tag without asking the user first. Steps that do so are marked **(ask first)**.
- Third-party GitHub Actions are pinned by commit SHA.

## Review Focus

Conditions the spec implies but does not list as tests. Each is pinned by a step in `test/smoke.sh` (Task 2).

1. `ARGS` holding several whitespace-separated flags: every flag must take effect, not only the first. (Smoke step 7.)
2. A user outside `node-exporter-textfile-writers` must not be able to write either textfile directory; a member must, and the service must be able to read what the member wrote. (Smoke step 6.)
3. After a reboot `/run` is empty: the volatile directory must come back from the installed `tmpfiles.d` entry without the package being reconfigured. (Smoke step 5.)
4. An admin who disabled the service: an upgrade must not re-enable or start it. (Smoke step 8.)
5. `dpkg --remove` (not purge) followed by a reinstall: the service must come back enabled and running with the kept config. (Smoke step 9.)

## File Structure

| File | Responsibility |
|---|---|
| `.gitattributes` | Force LF so scripts work when checked out on Windows |
| `.editorconfig` | Indentation for shell and YAML |
| `.gitignore` | Ignore `dist/`, `.worktrees/`, `.*.bak` |
| `versions.env` | The only place versions and hashes are pinned |
| `build.sh` | Download, verify, extract, invoke nFPM |
| `nfpm.yaml` | Package metadata and file mapping |
| `packaging/node-exporter.service` | systemd unit |
| `packaging/node-exporter.default` | Default `/etc/default/node-exporter` |
| `packaging/node-exporter.sysusers` | User and group declarations |
| `packaging/node-exporter.tmpfiles` | Textfile directory declarations |
| `packaging/scripts/postinstall.sh` | Create users and directories, enable, start or restart |
| `packaging/scripts/preremove.sh` | Stop on removal |
| `packaging/scripts/postremove.sh` | Mask on removal, clean up on purge |
| `test/smoke.sh` | End-to-end install test |
| `test/build-rejects.sh` | `build.sh` refuses bad input |
| `.github/workflows/build.yml` | CI build, test and release |
| `README.md`, `ROADMAP.md` | Usage, release procedure, future ideas |

---

### Task 1: Repository hygiene and v1 retirement

**Files:**
- Create: `.gitattributes`
- Modify: `.editorconfig`, `.gitignore`
- Retire: `make-deb.ps1`, `deb/`

**Interfaces:**
- Consumes: nothing.
- Produces: LF checkout for all later files; `.*.bak` ignored.

- [ ] **Step 1: Create `.gitattributes`**

```gitattributes
# Maintainer scripts and build scripts run on Linux; a CRLF checkout on
# Windows would put "\r" into shebangs and break them.
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
.*.bak
```

- [ ] **Step 4: Retire the v1 files**

```bash
TS=$(date +%Y%m%d%H%M%S)
mv make-deb.ps1 ".make-deb.ps1.$TS.bak"
mv deb ".deb.$TS.bak"
```

- [ ] **Step 5: Verify**

Run: `git add -A && git add --renormalize . && git status --short`
Expected: `A .gitattributes`, `M .editorconfig`, `M .gitignore`, `D` for `make-deb.ps1` and every file under `deb/`. No `.bak` entries listed.

- [ ] **Step 6: Commit**

```bash
git commit -m "Retire v1 packaging and enforce LF line endings"
```

---

### Task 2: End-to-end tests (written first, expected to fail)

**Files:**
- Create: `test/smoke.sh`, `test/build-rejects.sh`

**Interfaces:**
- Consumes (from later tasks): `versions.env` defining `NODE_EXPORTER_VERSION` and `PACKAGE_REVISION`; `./build.sh <arch>`; `VERSIONS_FILE` override; `dist/staging/upstream/` as the extraction directory.
- Produces: `test/smoke.sh <path-to-deb>` (root, systemd host, exit 0 on success); `test/build-rejects.sh` (no arguments, exit 0 on success).

- [ ] **Step 1: Create `test/smoke.sh`**

```bash
#!/usr/bin/env bash
# Destructive: installs, reconfigures and purges node-exporter on this host.
# Run it only on a disposable systemd machine (CI runner, throw-away VM).
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <path-to-deb>" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 2; }
DEB=$(realpath "$1")

cd "$(dirname "$0")/.."
# shellcheck source=versions.env
. ./versions.env

SERVICE=node-exporter.service
WRITERS=node-exporter-textfile-writers
PERSISTENT_DIR=/var/lib/node-exporter/textfile-collector
VOLATILE_DIR=/run/node-exporter/textfile-collector
CONFIG=/etc/default/node-exporter
DEFAULT_URL=http://localhost:9100/metrics
MOVED_URL=http://127.0.0.1:9101/metrics
METRICS=""

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

diagnostics() {
    status=$?
    if [ "$status" -ne 0 ]; then
        systemctl status "$SERVICE" --no-pager || true
        journalctl --unit "$SERVICE" --lines 50 --no-pager || true
    fi
    exit "$status"
}
trap diagnostics EXIT

# The body is captured before matching: `curl | grep -q` under pipefail
# fails with SIGPIPE as soon as grep finds its match.
wait_for_metrics() {
    for _ in $(seq 1 30); do
        if METRICS=$(curl --fail --silent "$1"); then
            return 0
        fi
        sleep 0.5
    done
    fail "no response from $1"
}
has_metric() { grep -Eq "$1" <<<"$METRICS"; }

step "1. Package metadata and contents"
EXPECTED_VERSION="${NODE_EXPORTER_VERSION}-${PACKAGE_REVISION}"
[ "$(dpkg-deb --field "$DEB" Package)" = "node-exporter" ] || fail "wrong package name"
[ "$(dpkg-deb --field "$DEB" Version)" = "$EXPECTED_VERSION" ] || fail "wrong version"
[ "$(dpkg-deb --field "$DEB" Architecture)" = "$(dpkg --print-architecture)" ] || fail "wrong architecture"
CONTENTS=$(dpkg-deb --contents "$DEB")
has_entry() { grep -Eq "^$1 root/root .* \\.?$2\$" <<<"$CONTENTS" || fail "missing or wrong mode: $2"; }
has_entry "-rwxr-xr-x" /usr/bin/node-exporter
has_entry "-rw-r--r--" /usr/lib/systemd/system/node-exporter.service
has_entry "-rw-r--r--" /etc/default/node-exporter
has_entry "-rw-r--r--" /usr/lib/sysusers.d/node-exporter.conf
has_entry "-rw-r--r--" /usr/lib/tmpfiles.d/node-exporter.conf
has_entry "-rw-r--r--" /usr/share/doc/node-exporter/LICENSE
has_entry "-rw-r--r--" /usr/share/doc/node-exporter/NOTICE
CONFFILES=$(dpkg-deb --info "$DEB" conffiles)
grep -Fxq "$CONFIG" <<<"$CONFFILES" || fail "$CONFIG is not a conffile"

step "2. Fresh install starts and enables the service"
dpkg --install "$DEB"
systemctl is-enabled --quiet "$SERVICE" || fail "service not enabled"
wait_for_metrics "$DEFAULT_URL"
systemctl is-active --quiet "$SERVICE" || fail "service not active"

step "3. Runs as the dedicated user"
getent passwd node-exporter >/dev/null || fail "user missing"
getent group "$WRITERS" >/dev/null || fail "writers group missing"
PID=$(systemctl show --property MainPID --value "$SERVICE")
[ "$(stat --format %U "/proc/$PID")" = "node-exporter" ] || fail "service runs as the wrong user"

step "4. Serves the pinned upstream version"
has_metric "^node_exporter_build_info\\{.*version=\"${NODE_EXPORTER_VERSION}\"" || fail "wrong upstream version"
has_metric '^node_scrape_collector_success\{collector="time"\} 1$' || fail "time collector not on by default"

step "5. Textfile directories exist and the volatile one survives a reboot"
EXPECTED_DIR_STAT="2775 root $WRITERS"
[ "$(stat --format '%a %U %G' "$PERSISTENT_DIR")" = "$EXPECTED_DIR_STAT" ] || fail "persistent dir has wrong mode or owner"
[ "$(stat --format '%a %U %G' "$VOLATILE_DIR")" = "$EXPECTED_DIR_STAT" ] || fail "volatile dir has wrong mode or owner"
# A reboot empties /run and then runs systemd-tmpfiles with no file argument,
# reading the standard directories. Doing the same here proves the entry is
# installed where boot will find it.
mv /run/node-exporter "/run/.node-exporter.$$.bak"
systemd-tmpfiles --create --prefix=/run/node-exporter
[ "$(stat --format '%a %U %G' "$VOLATILE_DIR")" = "$EXPECTED_DIR_STAT" ] || fail "volatile dir not recreated by tmpfiles.d"

step "6. Only group members can publish, and the service reads what they publish"
if runuser --user nobody -- touch "$PERSISTENT_DIR/intruder.prom" 2>/dev/null; then
    fail "non-member could write the persistent dir"
fi
if runuser --user nobody -- touch "$VOLATILE_DIR/intruder.prom" 2>/dev/null; then
    fail "non-member could write the volatile dir"
fi
runuser --user nobody --group "$WRITERS" -- sh -c "echo 'smoke_persistent 1' >'$PERSISTENT_DIR/smoke.prom'"
runuser --user nobody --group "$WRITERS" -- sh -c "echo 'smoke_volatile 1' >'$VOLATILE_DIR/smoke.prom'"
wait_for_metrics "$DEFAULT_URL"
has_metric '^smoke_persistent 1$' || fail "persistent textfile metric not served"
has_metric '^smoke_volatile 1$' || fail "volatile textfile metric not served"
has_metric '^node_textfile_scrape_error 0$' || fail "textfile collector reports an error"

step "7. Config edits survive a reinstall and every flag in ARGS applies"
echo 'ARGS="--web.listen-address=127.0.0.1:9101 --no-collector.time"' >"$CONFIG"
EDITED=$(cat "$CONFIG")
dpkg --install "$DEB"
[ "$(cat "$CONFIG")" = "$EDITED" ] || fail "reinstall overwrote $CONFIG"
wait_for_metrics "$MOVED_URL"
if has_metric '^node_scrape_collector_success\{collector="time"\}'; then
    fail "second flag in ARGS was ignored"
fi
has_metric '^smoke_persistent 1$' || fail "packaged textfile flags lost when ARGS is set"

step "8. A service the admin disabled stays disabled across an upgrade"
systemctl disable --now "$SERVICE"
dpkg --install "$DEB"
if systemctl is-enabled --quiet "$SERVICE"; then fail "upgrade re-enabled a disabled service"; fi
if systemctl is-active --quiet "$SERVICE"; then fail "upgrade started a disabled service"; fi
systemctl enable --now "$SERVICE"
wait_for_metrics "$MOVED_URL"

step "9. Remove keeps config; reinstall comes back enabled and running"
dpkg --remove node-exporter
if systemctl is-active --quiet "$SERVICE"; then fail "service still running after remove"; fi
[ "$(cat "$CONFIG")" = "$EDITED" ] || fail "remove deleted $CONFIG"
dpkg --install "$DEB"
systemctl is-enabled --quiet "$SERVICE" || fail "service not enabled after reinstall"
wait_for_metrics "$MOVED_URL"

step "10. Purge cleans up"
dpkg --purge node-exporter
[ ! -e /usr/lib/systemd/system/node-exporter.service ] || fail "unit file left behind"
[ ! -L /etc/systemd/system/multi-user.target.wants/node-exporter.service ] || fail "enablement symlink left behind"
[ ! -L /etc/systemd/system/node-exporter.service ] || fail "mask left behind"
[ ! -e "$CONFIG" ] || fail "$CONFIG left behind"
[ ! -e /var/lib/node-exporter ] || fail "/var/lib/node-exporter left behind"
[ ! -e /run/node-exporter ] || fail "/run/node-exporter left behind"
getent passwd node-exporter >/dev/null || fail "system user was removed (Debian convention keeps it)"

printf '\nAll smoke checks passed.\n'
```

- [ ] **Step 2: Create `test/build-rejects.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ./build.sh 2>/dev/null; then fail "accepted a missing architecture"; fi
if ./build.sh mips 2>/dev/null; then fail "accepted an unknown architecture"; fi

TAMPERED=$(mktemp)
trap 'rm -f "$TAMPERED"' EXIT
ZEROS=0000000000000000000000000000000000000000000000000000000000000000
sed -E "s/^(NODE_EXPORTER_SHA256_[A-Z0-9]+)=.*/\\1=${ZEROS}/" versions.env >"$TAMPERED"
if VERSIONS_FILE="$TAMPERED" ./build.sh amd64 2>/dev/null; then
    fail "accepted a tarball with the wrong hash"
fi
# build.sh recreates dist/staging on every run and extracts only after the
# hash check, so this directory existing means unverified bytes were unpacked.
[ ! -e dist/staging/upstream ] || fail "extracted a tarball that failed verification"

echo "build.sh rejects bad input."
```

- [ ] **Step 3: Check syntax**

Run: `bash -n test/smoke.sh && bash -n test/build-rejects.sh && echo ok`
Expected: `ok`

- [ ] **Step 4: Confirm the test fails for the right reason (ask first)**

Run: `bash test/build-rejects.sh`
Expected: non-zero exit with `sed: can't read versions.env: No such file or directory`, because neither `versions.env` nor `build.sh` exists yet. (The two architecture checks pass vacuously at this point: a missing `build.sh` also exits non-zero.) `test/smoke.sh` cannot run until a `.deb` exists; it first runs in Task 5.

- [ ] **Step 5: Commit**

Git on Windows does not record the executable bit from the filesystem, so set it in the index.

```bash
git add --chmod=+x test/smoke.sh test/build-rejects.sh
git commit -m "Add end-to-end tests for the package and the build script"
```

---

### Task 3: Package payload

**Files:**
- Create: `packaging/node-exporter.service`, `packaging/node-exporter.default`, `packaging/node-exporter.sysusers`, `packaging/node-exporter.tmpfiles`, `packaging/scripts/postinstall.sh`, `packaging/scripts/preremove.sh`, `packaging/scripts/postremove.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the seven files above at exactly these paths, referenced by `nfpm.yaml` in Task 4. Installed names: `/usr/lib/systemd/system/node-exporter.service`, `/etc/default/node-exporter`, `/usr/lib/sysusers.d/node-exporter.conf`, `/usr/lib/tmpfiles.d/node-exporter.conf`.

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

### Task 4: Version pins, nFPM config and build script

**Files:**
- Create: `versions.env`, `nfpm.yaml`, `build.sh`

**Interfaces:**
- Consumes: the `packaging/` files from Task 3.
- Produces:
  - `versions.env` with `NODE_EXPORTER_VERSION`, `PACKAGE_REVISION`, `NODE_EXPORTER_SHA256_AMD64`, `NODE_EXPORTER_SHA256_ARM64`.
  - `./build.sh <amd64|arm64>` writing `dist/node-exporter_<version>-<revision>_<arch>.deb`; exit 2 on bad usage; non-zero on any failure; honours `VERSIONS_FILE`.
  - `nfpm.yaml` reading `PACKAGE_ARCH`, `PACKAGE_VERSION`, `PACKAGE_REVISION` from the environment and upstream files from `dist/staging/upstream/`.

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
maintainer: Ilya Vassyutovich <IlyaVassyutovich@users.noreply.github.com>
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

# Modes and owners are spelled out on every entry because a build on Windows
# has no meaningful file modes to inherit.
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
# VERSIONS_FILE exists so the hash check can be exercised with a tampered copy.
# shellcheck source=versions.env
. "${VERSIONS_FILE:-./versions.env}"

case "$ARCH" in
    amd64) EXPECTED_SHA256=$NODE_EXPORTER_SHA256_AMD64 ;;
    arm64) EXPECTED_SHA256=$NODE_EXPORTER_SHA256_ARM64 ;;
    *) usage ;;
esac

for tool in nfpm curl tar sha256sum; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

TARBALL_NAME="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL_NAME}"
STAGING=dist/staging
TARBALL="$STAGING/upstream.tar.gz"

# Recreated on every run so one architecture's binary can never end up in
# another architecture's package.
rm -rf "$STAGING"
mkdir -p "$STAGING"

curl --fail --silent --show-error --location --output "$TARBALL" "$URL"
echo "Downloaded $TARBALL_NAME"

echo "${EXPECTED_SHA256}  ${TARBALL}" | sha256sum --check --strict --quiet
echo "Verified SHA256"

mkdir "$STAGING/upstream"
tar --extract --gzip --file "$TARBALL" --directory "$STAGING/upstream" --strip-components 1

export PACKAGE_ARCH=$ARCH
export PACKAGE_VERSION=$NODE_EXPORTER_VERSION
export PACKAGE_REVISION
nfpm package --config nfpm.yaml --packager deb --target dist/
```

- [ ] **Step 4: Check syntax**

Run: `bash -n build.sh && echo ok`
Expected: `ok`

- [ ] **Step 5: Run the rejection test (ask first)**

Run: `bash test/build-rejects.sh`
Expected: `build.sh rejects bad input.` Without `nfpm` on `PATH` (the case on this machine) the tampered-hash run stops at the tool check before downloading anything, so the hash check itself is not exercised locally; only the two architecture checks are. The hash check is exercised for real in CI (Task 5), where nFPM is installed.

- [ ] **Step 6: Optional local build (ask first)**

nFPM is not installed on this machine. If the user wants a local build: `go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.47.0`, then run `bash build.sh amd64`.
Expected: `dist/node-exporter_1.12.1-1_amd64.deb` exists. If nFPM reports that `${PACKAGE_ARCH}` or `${PACKAGE_REVISION}` was not expanded, stop and report it; the fix is to pass those values some other way, and that is a design change.

- [ ] **Step 7: Commit**

```bash
git add versions.env nfpm.yaml
git add --chmod=+x build.sh
git commit -m "Add pinned versions, nFPM config and build script"
```

---

### Task 5: GitHub Actions workflow and first CI run

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `./build.sh <arch>`, `test/build-rejects.sh`, `test/smoke.sh <deb>`, `versions.env`.
- Produces: artifacts `deb-amd64` and `deb-arm64`; on a tag, a GitHub Release with both `.deb` files and `SHA256SUMS`.

- [ ] **Step 1: Create `.github/workflows/build.yml`**

```yaml
name: build

on:
  push:
    branches: [master]
    tags: ["v*"]
  pull_request:

permissions:
  contents: read

env:
  NFPM_VERSION: 2.47.0

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
            nfpm_asset: Linux_x86_64
            nfpm_sha256: 0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783
          - arch: arm64
            runner: ubuntu-24.04-arm
            nfpm_asset: Linux_arm64
            nfpm_sha256: 1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Install nFPM
        env:
          NFPM_ASSET: ${{ matrix.nfpm_asset }}
          NFPM_SHA256: ${{ matrix.nfpm_sha256 }}
        run: |
          archive="$RUNNER_TEMP/nfpm.tar.gz"
          curl --fail --silent --show-error --location --output "$archive" \
            "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_${NFPM_ASSET}.tar.gz"
          echo "${NFPM_SHA256}  ${archive}" | sha256sum --check --strict
          mkdir "$RUNNER_TEMP/nfpm"
          tar --extract --gzip --file "$archive" --directory "$RUNNER_TEMP/nfpm" nfpm
          echo "$RUNNER_TEMP/nfpm" >>"$GITHUB_PATH"

      - name: Lint shell scripts
        # The scripts are identical on both architectures; one pass is enough.
        if: matrix.arch == 'amd64'
        run: shellcheck --external-sources build.sh test/*.sh packaging/scripts/*.sh

      - name: Build script rejects bad input
        run: test/build-rejects.sh

      - name: Build package
        run: ./build.sh ${{ matrix.arch }}

      - name: Smoke test
        run: sudo test/smoke.sh dist/node-exporter_*_${{ matrix.arch }}.deb

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: deb-${{ matrix.arch }}
          path: dist/*.deb
          if-no-files-found: error

  release:
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Tag must match versions.env
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
        run: sha256sum -- *.deb >SHA256SUMS

      - name: Publish release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$GITHUB_REF_NAME" dist/*.deb dist/SHA256SUMS \
            --verify-tag --title "$GITHUB_REF_NAME" --generate-notes
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add build, test and release workflow"
```

- [ ] **Step 3: Push and open a draft pull request (ask first)**

The workflow triggers on pull requests, so a PR is what makes CI run on this branch.

```bash
git push origin feature/nfpm-pipeline
gh pr create --draft --base master --head feature/nfpm-pipeline \
  --title "Package node-exporter with nFPM" \
  --body "Replaces the v1 dpkg-deb script with an nFPM pipeline. Spec: docs/superpowers/specs/2026-10-05-nfpm-pipeline-design.md"
```

- [ ] **Step 4: Watch the run**

Run: `gh pr checks --watch`
Expected: `build (amd64)` and `build (arm64)` pass; `release` is skipped.

- [ ] **Step 5: Fix what CI finds**

This is the first time `test/smoke.sh` runs, so failures here are expected and are the point of the test. Read the failing step with `gh run view --log-failed`, fix the root cause in the owning file, and commit each fix separately with a message naming the cause. Do not weaken an assertion to get green; if an assertion turns out to describe behaviour that is wrong, stop and raise it with the user. Repeat Step 4 until both jobs pass.

---

### Task 6: Documentation

**Files:**
- Modify: `README.md`, `ROADMAP.md`

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing documentation.

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

## Build locally

Needs `nfpm`, `curl`, `tar` and `sha256sum` (Git Bash works on Windows).

```sh
./build.sh amd64
```

The package is written to `dist/`.

`test/smoke.sh <deb>` installs, exercises and purges the package. It is destructive, so run it only as root on a disposable machine.

## Release

1. Edit `versions.env`: set the new upstream version and both hashes with `PACKAGE_REVISION=1`, or raise `PACKAGE_REVISION` for a packaging-only change.
2. Merge to `master` and wait for a green build.
3. Tag the merge commit `v<version>-<revision>`, for example `v1.12.1-1`, and push the tag.

The workflow refuses to publish if the tag does not match `versions.env`.

![wzrd](https://wzrd.iv.link)
````

- [ ] **Step 2: Replace `ROADMAP.md`**

```markdown
- [ ] Publish a signed apt repository so hosts update through `apt upgrade`
- [ ] Track upstream node_exporter releases automatically
- [ ] Build for armhf
```

- [ ] **Step 3: Commit and push (ask first before pushing)**

```bash
git add README.md ROADMAP.md
git commit -m "Document install, build and release for the nFPM pipeline"
git push origin feature/nfpm-pipeline
```

- [ ] **Step 4: Hand over**

Report to the user: CI status, the PR link, and the two `.bak` paths created in Task 1 as candidates for clean-up. Cutting the first release (merging and tagging `v1.12.1-1`) is the user's call.

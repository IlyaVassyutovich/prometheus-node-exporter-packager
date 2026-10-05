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

The only requirement is Docker or Podman; the commands are the same for both (replace `podman` with `docker`).

Build the package and copy it to `dist/`:

```sh
podman build --target package --tag node-exporter-package .
podman create --name node-exporter-package node-exporter-package
podman cp node-exporter-package:/dist/. dist
podman rm node-exporter-package
```

Test it:

```sh
podman build --target test --tag node-exporter-smoke .
podman run --rm --tty --privileged node-exporter-smoke
```

The test boots a throw-away Debian container with systemd, installs the package in it and checks that the exporter runs. Among systemd's own boot messages it prints `SMOKE PASS` and exits 0 on success, or `SMOKE FAIL: <reason>` and a non-zero code.

Add `--platform linux/arm64` to the first `build` to produce the other architecture. The test runs on your machine's own architecture.

In Git Bash on Windows, prefix the `cp` command with `MSYS_NO_PATHCONV=1`, otherwise the shell rewrites the container path.

## Release

1. Edit `versions.env`: set the new upstream version and both hashes with `PACKAGE_REVISION=1`, or raise `PACKAGE_REVISION` for a packaging-only change.
2. Optional: run the `build` workflow by hand on your branch (Actions tab, or `gh workflow run build --ref <branch>`). It publishes a pre-release you can try on a host; its version sorts below the final one, so the final release installs over it as a normal upgrade.
3. Merge to `master` and wait for a green build.
4. Tag the merge commit `v<version>-<revision>`, for example `v1.12.1-1`, and push the tag.

The workflow refuses to publish a release if the tag does not match `versions.env`. Pre-releases are not cleaned up automatically.

![wzrd](https://wzrd.iv.link)

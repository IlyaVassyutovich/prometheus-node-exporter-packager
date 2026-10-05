#!/bin/sh
set -e

# Only on removal: during an upgrade the old process keeps serving until
# postinstall restarts it, which avoids a gap in metrics.
if [ "$1" = "remove" ] && [ -d /run/systemd/system ]; then
    deb-systemd-invoke stop node-exporter.service >/dev/null || true
fi

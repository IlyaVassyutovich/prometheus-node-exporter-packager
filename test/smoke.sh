#!/bin/sh
set -eu

# Every check reports its outcome, so a log shows how far a run got and not
# only where it stopped.
check() {
    description=$1
    shift
    if "$@"; then
        echo "SMOKE ok: $description"
    else
        echo "SMOKE FAIL: $description"
        exit 1
    fi
}

# curl stays fully silent because it would report every refused retry while
# the listener is still coming up as an error.
fetch_metrics() {
    metrics=$(curl --fail --silent \
        --retry 10 --retry-delay 1 --retry-connrefused \
        http://localhost:9100/metrics)
}

serves() { printf '%s\n' "$metrics" | grep -q "$1"; }

# Installed on the running system rather than while building the image,
# because that is the path a real host takes: postinstall has to create the
# user and directories and start the service itself.
check "package installs" dpkg --install /smoke/*.deb
check "service is enabled" systemctl is-enabled --quiet node-exporter.service

echo 'smoke_persistent 1' >/var/lib/node-exporter/textfile-collector/smoke.prom
echo 'smoke_volatile 1' >/run/node-exporter/textfile-collector/smoke.prom

check "exporter answers on port 9100" fetch_metrics
check "exporter reports version ${NODE_EXPORTER_VERSION}" \
    serves "^node_exporter_build_info{.*version=\"${NODE_EXPORTER_VERSION}\""
check "metric from the persistent textfile directory is served" serves '^smoke_persistent 1$'
check "metric from the volatile textfile directory is served" serves '^smoke_volatile 1$'

echo "SMOKE PASS"

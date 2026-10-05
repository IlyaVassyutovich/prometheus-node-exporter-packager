#!/bin/sh
set -eu

fail() {
    echo "SMOKE FAIL: $*"
    exit 1
}

# Installed on the running system rather than while building the image,
# because that is the path a real host takes: postinstall has to create the
# user and directories and start the service itself.
dpkg --install /smoke/*.deb || fail "package did not install"

systemctl is-enabled --quiet node-exporter.service || fail "service is not enabled"

echo 'smoke_persistent 1' >/var/lib/node-exporter/textfile-collector/smoke.prom
echo 'smoke_volatile 1' >/run/node-exporter/textfile-collector/smoke.prom

# The listener needs a moment after the unit has been started. curl stays
# fully silent because it would report every refused retry as an error.
metrics=$(curl --fail --silent \
    --retry 10 --retry-delay 1 --retry-connrefused \
    http://localhost:9100/metrics) || fail "no answer on port 9100"

serves() { printf '%s\n' "$metrics" | grep -q "$1"; }

serves "^node_exporter_build_info{.*version=\"${NODE_EXPORTER_VERSION}\"" \
    || fail "exporter does not report version ${NODE_EXPORTER_VERSION}"
serves '^smoke_persistent 1$' || fail "metric from the persistent textfile directory is not served"
serves '^smoke_volatile 1$' || fail "metric from the volatile textfile directory is not served"

echo "SMOKE PASS: node-exporter ${NODE_EXPORTER_VERSION} installs, runs and reads both textfile directories"

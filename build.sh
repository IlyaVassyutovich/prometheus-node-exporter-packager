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
export PACKAGE_REVISION
nfpm package --config nfpm.yaml --packager deb --target dist/

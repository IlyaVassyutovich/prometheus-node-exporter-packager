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

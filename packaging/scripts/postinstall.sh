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

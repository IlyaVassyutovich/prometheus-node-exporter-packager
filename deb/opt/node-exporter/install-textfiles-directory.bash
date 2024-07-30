#!/usr/bin/env bash

USERNAME="node-exporter"
TEXTFILE_WRITERS="node-exporter-textfile-writers"

install \
    --directory \
    --owner $USERNAME \
    --group $TEXTFILE_WRITERS \
    --mode 0770 \
    /var/run/node-exporter-textfiles/

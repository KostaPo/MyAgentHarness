#!/bin/bash
set -e

if [ -d /workspace/.git ]; then
    mkdir -p /workspace/.git/info
    grep -qxF 'AGENTS.md' /workspace/.git/info/exclude 2>/dev/null || \
        echo 'AGENTS.md' >> /workspace/.git/info/exclude
fi

exec pi "$@"
#!/bin/bash
# Rebuilds and launches OmniOmics in development mode -- meant to be the target
# of a .desktop launcher, not for distribution (see build.sh for that).
#
# Two things the binary alone does not solve:
#   - GDK_BACKEND=x11: on this machine GTK/Flutter draws no window at all under
#     native Wayland, and does so silently -- the process starts, the backend
#     starts, and no UI appears. Forcing XWayland is the confirmed workaround.
#   - flutter build before launching: the bundle is AOT-compiled, so changed
#     Dart code only appears after a rebuild, not by reopening the old binary.
#
# OMNIOMICS_DEV_RELOAD=1 enables a watcher (backend/main.py) that reloads
# pipeline.yaml without restarting the app. It exists only while that variable
# is set, so build.sh and the packaged build never turn it on.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")/app"

# .desktop launchers do not source .bashrc (only interactive shells do), so the
# PATH inherited from systemd/GNOME does not include flutter -- without this the
# build would fail with "flutter: command not found" only when opened
# pelo ícone, mesmo funcionando normalmente num terminal.
export PATH="$HOME/development/flutter/bin:$PATH"

flutter build linux --debug

export GDK_BACKEND=x11
export OMNIOMICS_DEV_RELOAD=1
exec ./build/linux/x64/debug/bundle/omniomics

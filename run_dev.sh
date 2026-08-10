#!/bin/bash
# Recompila e abre o OmniOmics em modo dev -- pensado para ser o alvo de um
# lançador .desktop, não para distribuição (ver build.sh para isso).
#
# Duas coisas que o binário sozinho não resolve:
#   - GDK_BACKEND=x11: nesta máquina, GTK/Flutter não desenha janela nenhuma
#     sob Wayland nativo (silencioso -- processo sobe, backend sobe, sem UI).
#     Forçar XWayland é o que já confirmamos que funciona.
#   - flutter build antes de abrir: o bundle é AOT: código Dart mudado só
#     aparece depois de recompilar, não só reabrir o binário antigo.
#
# OMNIOMICS_DEV_RELOAD=1 liga um watcher (backend/main.py) que recarrega
# pipeline.yaml sem precisar fechar o app -- só existe enquanto essa env var
# está setada, então o build.sh/pacote final nunca ativa isso.
set -euo pipefail
cd "$(dirname "$(realpath "$0")")/app"

# Lançadores .desktop não passam pelo .bashrc (só shells interativos fazem
# isso), então o PATH herdado do systemd/GNOME não inclui o flutter -- sem
# isso o build falharia com "flutter: command not found" só quando aberto
# pelo ícone, mesmo funcionando normalmente num terminal.
export PATH="$HOME/development/flutter/bin:$PATH"

flutter build linux --debug

export GDK_BACKEND=x11
export OMNIOMICS_DEV_RELOAD=1
exec ./build/linux/x64/debug/bundle/omniomics

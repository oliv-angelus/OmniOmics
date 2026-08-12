#!/bin/bash
# Gera o pacote distribuível do OmniOmics:
#   dist/omniomics_<version>_amd64.deb  — instalável via dpkg/apt
#
# Pré-requisitos: python3-venv, flutter (linux desktop enabled), dpkg-deb, fakeroot
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"

VERSION="0.0.1"
PKG_NAME="omniomics"
BIN_NAME="omniomics"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { printf "${GREEN}[build]${NC} %s\n" "$*"; }
error() { printf "${RED}[erro]${NC} %s\n" "$*" >&2; exit 1; }

command -v flutter &>/dev/null || error "flutter não encontrado no PATH."

# ─── Preparar venv Python ─────────────────────────────────────────────────
PYTHON=$(command -v python3 || command -v python || true)
[ -z "$PYTHON" ] && error "Python 3 não encontrado."

if [ ! -f ".venv/bin/python" ]; then
    info "Criando ambiente virtual Python..."
    "$PYTHON" -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt

# ─── 1. Compilar backend com PyInstaller ──────────────────────────────────
info "Instalando PyInstaller..."
pip install -q pyinstaller

info "Compilando backend Python → backend/dist/server..."
pyinstaller backend/main.py \
    --onefile \
    --name server \
    --distpath backend/dist \
    --workpath /tmp/omniomics-pyinstaller \
    --specpath /tmp/omniomics-pyinstaller \
    --paths backend \
    --hidden-import uvicorn.logging \
    --hidden-import uvicorn.loops \
    --hidden-import uvicorn.loops.auto \
    --hidden-import uvicorn.protocols \
    --hidden-import uvicorn.protocols.http \
    --hidden-import uvicorn.protocols.http.auto \
    --hidden-import uvicorn.protocols.websockets \
    --hidden-import uvicorn.protocols.websockets.auto \
    --hidden-import uvicorn.protocols.websockets.websockets_impl \
    --hidden-import uvicorn.lifespan \
    --hidden-import uvicorn.lifespan.on \
    --hidden-import fastapi \
    --hidden-import aiofiles \
    --hidden-import httpx \
    --hidden-import psutil \
    --hidden-import yaml \
    --collect-all websockets \
    --noconfirm \
    --log-level WARN

[ -x "backend/dist/server" ] || error "PyInstaller não gerou backend/dist/server."
info "Backend compilado: $(du -sh backend/dist/server | cut -f1)"

# ─── 2. Compilar app Flutter (release) ────────────────────────────────────
info "Compilando app Flutter (linux release)..."
(cd app && flutter build linux --release)

BUNDLE_DIR="app/build/linux/x64/release/bundle"
[ -x "$BUNDLE_DIR/omniomics" ] || error "Flutter não gerou $BUNDLE_DIR/omniomics."

# ─── 3. Montar staging (/opt/omniomics) ───────────────────────────────────
info "Montando árvore do pacote..."
STAGE="dist/staging"
rm -rf "$STAGE"
INSTALL_DIR="$STAGE/opt/$PKG_NAME"
mkdir -p "$INSTALL_DIR" "$STAGE/DEBIAN" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/pixmaps"

cp -r "$BUNDLE_DIR"/. "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/backend"
cp backend/dist/server "$INSTALL_DIR/backend/server"
cp -r pipelines "$INSTALL_DIR/pipelines"
# plots/ is NOT optional: plots_engine resolves PLOTS_DIR as <binary>/../plots,
# so without it the whole Plots tab fails at run time in the packaged build
# while working perfectly in development. It holds the analysis manifest, the R
# scripts and the r-plots conda spec.
cp -r plots "$INSTALL_DIR/plots"
# Shipped so the licence travels with the binary, which the MIT terms require.
cp LICENSE "$INSTALL_DIR/LICENSE"
cp README.md "$INSTALL_DIR/README.md"

ln -sf "/opt/$PKG_NAME/$BIN_NAME" "$STAGE/usr/bin/$BIN_NAME"
cp build/app_icon.png "$STAGE/usr/share/pixmaps/$PKG_NAME.png"

cat > "$STAGE/usr/share/applications/$PKG_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OmniOmics
Comment=Visual interface for multi-omics bioinformatics pipelines
Exec=/opt/$PKG_NAME/$BIN_NAME
Icon=$PKG_NAME
Categories=Science;Biology;
Terminal=false
EOF

INSTALLED_SIZE=$(du -sk "$INSTALL_DIR" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: science
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_SIZE
Recommends: conda | miniforge3
Maintainer: OmniOmics <sch.felipe.01@gmail.com>
Description: Integrated desktop environment for multi-omics analysis
 OmniOmics packages five Snakemake workflows behind a graphical interface,
 with an integrated plotting environment that turns each workflow's output
 into publication-ready figures: MAGMA (metagenomics), SIGMA (isolate
 genomics), DOGMA (metatranscriptomics), DEFINE (differential expression)
 and PRISM (amplicon sequencing).
 .
 Alpha release: run end to end and covered by an automated test suite, but
 not yet in sustained use on real data beyond the author.
EOF

# ─── 4. Gerar .deb ─────────────────────────────────────────────────────────
info "Gerando .deb..."
mkdir -p dist
fakeroot dpkg-deb --build "$STAGE" "dist/${PKG_NAME}_${VERSION}_amd64.deb"

echo ""
info "=== Pacote gerado ==="
ls -lh dist/*.deb
echo ""
info "Para instalar:  sudo dpkg -i dist/${PKG_NAME}_${VERSION}_amd64.deb"
info "Depois:         $BIN_NAME   (ou pelo menu de aplicativos)"

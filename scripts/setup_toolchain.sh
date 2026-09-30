#!/usr/bin/env bash
# ==============================================================================
# Setup script for OSS CAD Suite on macOS (Apple Silicon / Intel)
# Tang Nano 20K FPGA Development
# ==============================================================================

set -euo pipefail

INSTALL_DIR="${HOME}/oss-cad-suite"

echo "======================================================================"
echo " OSS CAD Suite Toolchain Setup for macOS"
echo " Target: Sipeed Tang Nano 20K (Gowin GW2AR-18)"
echo " Destination: ${INSTALL_DIR}"
echo "======================================================================"

# 1. Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    OSS_ARCH="darwin-arm64"
    echo "[+] Detected Apple Silicon (arm64)"
elif [ "$ARCH" = "x86_64" ]; then
    OSS_ARCH="darwin-x64"
    echo "[+] Detected Intel Mac (x86_64)"
else
    echo "[-] Unsupported architecture: $ARCH"
    exit 1
fi

# 2. Check if already installed
if [ -d "$INSTALL_DIR/bin" ] && [ -x "$INSTALL_DIR/bin/yosys" ]; then
    echo "[!] OSS CAD Suite is already installed at $INSTALL_DIR"
    read -p "Do you want to re-download and reinstall? [y/N]: " -r RESP
    if [[ ! "$RESP" =~ ^[Yy]$ ]]; then
        echo "[+] Keeping existing installation."
        exit 0
    fi
fi

# 3. Fetch latest release URL from GitHub API
echo "[+] Querying GitHub for latest OSS CAD Suite release..."
DOWNLOAD_URL=$(curl -s "https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest" \
    | grep "browser_download_url.*${OSS_ARCH}.*\.tgz\"" \
    | head -n 1 \
    | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[-] Failed to fetch download URL from GitHub API. Please check your internet connection."
    exit 1
fi

TAR_NAME=$(basename "$DOWNLOAD_URL")
TMP_TAR="/tmp/${TAR_NAME}"

echo "[+] Downloading ${TAR_NAME}..."
echo "    URL: ${DOWNLOAD_URL}"
curl -L --progress-bar -o "$TMP_TAR" "$DOWNLOAD_URL"

# 4. Extract
echo "[+] Extracting to ${HOME}..."
mkdir -p "$HOME"
tar -xzf "$TMP_TAR" -C "$HOME"
rm -f "$TMP_TAR"

# 5. Fix macOS Gatekeeper quarantine flags
echo "[+] Removing macOS quarantine flags from downloaded binaries..."
xattr -r -d com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true

# 6. Verify installation
echo "[+] Verifying toolchain..."
if [ -x "$INSTALL_DIR/bin/yosys" ]; then
    echo "    Yosys: OK"
else
    echo "[-] Yosys not found in extracted directory!"
    exit 1
fi

if [ -x "$INSTALL_DIR/bin/nextpnr-himbaechel" ] || [ -x "$INSTALL_DIR/bin/nextpnr-gowin" ]; then
    echo "    nextpnr: OK"
else
    echo "[-] nextpnr not found in extracted directory!"
    exit 1
fi

if [ -x "$INSTALL_DIR/bin/gowin_pack" ]; then
    echo "    gowin_pack: OK"
else
    echo "[-] gowin_pack not found in extracted directory!"
    exit 1
fi

echo "======================================================================"
echo " Toolchain setup complete!"
echo "======================================================================"
echo ""
echo "Note: The project's Makefile automatically checks ~/oss-cad-suite/bin."
echo "To also use the tools directly in your terminal sessions, add this to ~/.zshrc:"
echo ""
echo "    export PATH=\"\$HOME/oss-cad-suite/bin:\$PATH\""
echo ""
echo "Try running:"
echo "    make check-tools"
echo "    make"
echo ""

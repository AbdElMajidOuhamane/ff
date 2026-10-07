#!/bin/sh
# Fairyfly installer — https://github.com/AbdElMajidOuhamane/ff
# Usage: curl -fsSL <raw-url>/install.sh | sh
set -eu

REPO="AbdElMajidOuhamane/ff"
BIN_DIR="${FF_INSTALL_DIR:-$HOME/.local/bin}"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
    darwin) os=macos ;;
    linux)  os=linux ;;
    *) echo "ff install: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

arch=$(uname -m)
case "$arch" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) echo "ff install: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

asset="ff-${os}-${arch}"
base="https://github.com/${REPO}/releases/latest/download"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "Downloading ${asset} from the latest release..."
curl -fsSL -o "${tmp}/${asset}" "${base}/${asset}"
curl -fsSL -o "${tmp}/sha256sums.txt" "${base}/sha256sums.txt"

echo "Verifying SHA-256..."
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && grep "  ${asset}\$" sha256sums.txt | sha256sum -c -)
else
    (cd "$tmp" && grep "  ${asset}\$" sha256sums.txt | shasum -a 256 -c -)
fi

mkdir -p "$BIN_DIR"
mv "${tmp}/${asset}" "${BIN_DIR}/ff"
chmod +x "${BIN_DIR}/ff"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) echo "Note: add ${BIN_DIR} to your PATH:  export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo "Installed:"
"${BIN_DIR}/ff" --version

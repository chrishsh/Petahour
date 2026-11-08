#!/usr/bin/env bash
# One-time setup. Everything lands in one conda environment plus this folder, so removal is:
#   conda env remove -n petahour-poc   and   delete this folder
# Nothing is written to your shell profile.
set -euo pipefail
cd "$(dirname "$0")/.."

FOUNDRY_VERSION="v1.9.0"
FORGE_STD_VERSION="v1.17.0"
ENV_NAME="petahour-poc"
ENV_PREFIX="${PETAHOUR_ENV_PREFIX:-}"   # optional: an explicit path instead of a named environment

say() { printf '\n==> %s\n' "$1"; }
die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

case "$PWD" in
  *CloudStorage*|*"Google Drive"*|*Dropbox*|*OneDrive*|*iCloud*)
    die "This folder is inside a cloud-synced drive, which would try to sync about 30,000 dependency
files. Copy it somewhere local first, then run this again:
    cp -R \"$PWD\" ~/petahour-poc && cd ~/petahour-poc && bash scripts/bootstrap.sh" ;;
esac
case "$PWD" in *" "*) die "The path contains a space, which breaks some tools. Move it, for example to ~/petahour-poc." ;; esac

CONDA_BIN="${CONDA_EXE:-$(command -v conda || true)}"
if [ ! -x "$CONDA_BIN" ]; then
  for candidate in /opt/anaconda3/bin/conda "$HOME/anaconda3/bin/conda" "$HOME/miniconda3/bin/conda" /opt/miniconda3/bin/conda; do
    [ -x "$candidate" ] && CONDA_BIN="$candidate" && break
  done
fi
[ -x "$CONDA_BIN" ] || die "conda not found. Install Miniconda from https://docs.conda.io, then run this again."

say "Creating the Python and Node environment"
# conda-forge only. Without --override-channels, conda also reads Anaconda's default channels from
# your config, which can stop here at a Terms of Service prompt.
CONDA_ARGS=(--override-channels -c conda-forge python=3.12 "nodejs>=22,<23" pip)
if [ -n "$ENV_PREFIX" ]; then
  [ -d "$ENV_PREFIX/conda-meta" ] || "$CONDA_BIN" create -y -q -p "$ENV_PREFIX" "${CONDA_ARGS[@]}"
  PREFIX="$ENV_PREFIX"
else
  "$CONDA_BIN" env list | awk '{print $1}' | grep -qx "$ENV_NAME" || "$CONDA_BIN" create -y -q -n "$ENV_NAME" "${CONDA_ARGS[@]}"
  PREFIX="$("$CONDA_BIN" run -n "$ENV_NAME" python -c 'import sys; print(sys.prefix)')"
fi
export PATH="$PREFIX/bin:$PATH"
echo "environment: $PREFIX"

say "Installing Foundry $FOUNDRY_VERSION into the environment"
if ! "$PREFIX/bin/forge" --version 2>/dev/null | grep -q "${FOUNDRY_VERSION#v}"; then
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) die "unsupported OS: $(uname -s)" ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; *) die "unsupported CPU: $(uname -m)" ;; esac
  asset="foundry_${FOUNDRY_VERSION}_${os}_${arch}"
  url="https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSL "$url/$asset.tar.gz" -o "$tmp/$asset.tar.gz"
  curl -fsSL "$url/$asset.sha256" -o "$tmp/$asset.sha256"
  # The release publishes a checksum; a tampered or truncated download stops here.
  expected="$(awk '{print $1}' "$tmp/$asset.sha256")"
  actual="$( (shasum -a 256 "$tmp/$asset.tar.gz" 2>/dev/null || sha256sum "$tmp/$asset.tar.gz") | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "Foundry checksum mismatch: expected $expected, got $actual"
  tar -xzf "$tmp/$asset.tar.gz" -C "$PREFIX/bin"
  rm -rf "$tmp"
fi
forge --version | head -1

say "Installing Python packages"
python -m pip install -q -r requirements.txt

say "Installing Node packages from the lockfile"
npm ci --no-audit --no-fund --loglevel=error

say "Installing forge-std $FORGE_STD_VERSION"
[ -d lib/forge-std ] || forge install --no-git "foundry-rs/forge-std@$FORGE_STD_VERSION" >/dev/null

say "Compiling the contracts"
mkdir -p deployments reports
forge build >/dev/null
echo "compiled"

printf '\nSetup complete. Next:\n\n'
if [ -n "$ENV_PREFIX" ]; then printf '  export PATH="%s/bin:$PATH"\n' "$PREFIX"; else printf '  conda activate %s\n' "$ENV_NAME"; fi
printf '  make test\n  make demo\n\n'

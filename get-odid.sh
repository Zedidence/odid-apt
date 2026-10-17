#!/usr/bin/env bash
# ODID Sniffer: one-line installer for Raspberry Pi OS / Debian 13 (trixie).
#
#   curl -fsSL https://<your-repo>/get-odid.sh | \
#       sudo ODID_APT_REPO=https://<your-repo> ODID_KEY_FPR=<fingerprint> bash
#   sudo bash get-odid.sh --deb ./odid-sniffer_4.1.8-1_all.deb      # local package
#
# Options:
#   --deb FILE        install this .deb instead of using an apt repository
#   --repo URL        apt repository (flat repo made by make-apt-repo.sh);
#                     also read from $ODID_APT_REPO
#   --key-fpr FPR     expected signing-key fingerprint (also $ODID_KEY_FPR);
#                     published by whoever runs the repository
#   --tailscale       also install Tailscale (official installer) for remote access
#   --no-provision    skip "odid provision" (run it later with sudo)
set -euo pipefail

DEB=""
REPO="${ODID_APT_REPO:-}"
KEY_FPR="${ODID_KEY_FPR:-}"
TAILSCALE=0
PROVISION=1
KEYRING=/usr/share/keyrings/odid-archive-keyring.gpg

die()  { echo "  ✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deb) DEB="${2:?--deb needs a file}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a URL}"; shift 2 ;;
        --key-fpr) KEY_FPR="${2:?--key-fpr needs a fingerprint}"; shift 2 ;;
        --tailscale) TAILSCALE=1; shift ;;
        --no-provision) PROVISION=0; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
# shellcheck source=/dev/null
. /etc/os-release
if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
    echo "  ! This package targets Debian 13 (trixie) / Raspberry Pi OS based on it;"
    echo "    found ${PRETTY_NAME:-unknown}. Older releases lack recent enough"
    echo "    python3-typer/aiohttp; use install.sh from a git checkout instead."
    [[ -t 0 ]] || [[ -e /dev/tty ]] || die "unsupported OS"
    read -r -p "  Continue anyway? [y/N] " a </dev/tty || a=n
    [[ "${a,,}" == y ]] || exit 1
fi

export DEBIAN_FRONTEND=noninteractive
if [[ -n "$DEB" ]]; then
    [[ -f "$DEB" ]] || die "no such file: $DEB"
    apt-get update -q
    apt-get install -y "$(realpath "$DEB")"
elif [[ -n "$REPO" ]]; then
    [[ "$REPO" == https://* ]] || die "the repository URL must be https://"
    apt-get update -q
    apt-get install -y -q curl ca-certificates gnupg
    tmpkey="$(mktemp)"
    curl -fsSL "$REPO/odid-archive-keyring.gpg" -o "$tmpkey"
    got="$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
    [[ -n "$got" ]] || { rm -f "$tmpkey"; die "downloaded keyring is not a valid key"; }
    if [[ -n "$KEY_FPR" ]]; then
        want="$(echo "$KEY_FPR" | tr -d ' :' | tr '[:lower:]' '[:upper:]')"
        [[ "$got" == "$want" ]] || { rm -f "$tmpkey"; die "signing key $got does not match the expected $want"; }
        ok "Signing key verified: $got"
    else
        echo "  ! No --key-fpr given: trusting the repository's key $got on first use."
        echo "    Compare it with the fingerprint the repository owner published."
    fi
    install -m 0644 "$tmpkey" "$KEYRING"
    rm -f "$tmpkey"
    chmod 0644 "$KEYRING"
    echo "deb [signed-by=$KEYRING] $REPO ./" > /etc/apt/sources.list.d/odid.list
    apt-get update -q
    apt-get install -y odid-sniffer
else
    die "no package source: pass --deb FILE or --repo URL (or set ODID_APT_REPO)"
fi
ok "odid-sniffer installed ($(dpkg-query -W -f='${Version}' odid-sniffer))"

if [[ $TAILSCALE == 1 ]] && ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed. Log in with: sudo tailscale up"
fi

if [[ $PROVISION == 1 ]]; then
    if [[ -e /dev/tty ]]; then
        odid provision </dev/tty
    else
        odid provision --yes
    fi
fi

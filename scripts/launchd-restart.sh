#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launchd-common.sh"

prepare_launchd_env
require_command launchctl

TARGET_KIND="${1:-mcp}"
case "${TARGET_KIND}" in
  mcp)
    launchctl kickstart -k "$(launchctl_target "$(mcp_label)")"
    ;;
  cloudflared)
    launchctl kickstart -k "$(launchctl_target "$(cloudflared_label)")"
    ;;
  all)
    launchctl kickstart -k "$(launchctl_target "$(mcp_label)")"
    launchctl kickstart -k "$(launchctl_target "$(cloudflared_label)")"
    ;;
  *)
    echo "Usage: ./scripts/launchd-restart.sh [mcp|cloudflared|all]" >&2
    exit 1
    ;;
esac
echo "Restarted ${TARGET_KIND} launchd service(s)."

#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launchd-common.sh"

prepare_launchd_env
require_command launchctl

MCP_TARGET="$(launchctl_target "$(mcp_label)")"
launchctl print "${MCP_TARGET}" >/dev/null
launchctl kill HUP "${MCP_TARGET}"
echo "Sent HUP rolling-reload to ${MCP_TARGET}"

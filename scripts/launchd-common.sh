#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_SHELL_PATH="${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

load_env_file() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

resolve_path() {
  local value="$1"
  if [[ "${value}" = /* ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  printf '%s\n' "${ROOT_DIR}/${value}"
}

pick_cloudflared_config() {
  local candidate

  if [[ -n "${NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG:-}" ]]; then
    resolve_path "${NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG}"
    return 0
  fi

  for candidate in \
    "${ROOT_DIR}/cloudflared.local.yml" \
    "${ROOT_DIR}/cloudflared.local.yaml"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

pick_python() {
  local candidate
  for candidate in "${PYTHON_BIN:-}" python3.11 python3; do
    if [[ -n "${candidate}" ]] && command -v "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  echo "Python 3.11+ is required but no suitable interpreter was found." >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

prepare_launchd_env() {
  local override_host="${NOTION_LOCAL_OPS_HOST:-}"
  local override_port="${NOTION_LOCAL_OPS_PORT:-}"
  local override_workspace_root="${NOTION_LOCAL_OPS_WORKSPACE_ROOT:-}"
  local override_state_dir="${NOTION_LOCAL_OPS_STATE_DIR:-}"
  local override_auth_token="${NOTION_LOCAL_OPS_AUTH_TOKEN:-}"
  local override_cloudflared_config="${NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG:-}"
  local override_tunnel_name="${NOTION_LOCAL_OPS_TUNNEL_NAME:-}"
  local override_codex_command="${NOTION_LOCAL_OPS_CODEX_COMMAND:-}"
  local override_claude_command="${NOTION_LOCAL_OPS_CLAUDE_COMMAND:-}"
  local override_command_timeout="${NOTION_LOCAL_OPS_COMMAND_TIMEOUT:-}"
  local override_delegate_timeout="${NOTION_LOCAL_OPS_DELEGATE_TIMEOUT:-}"
  local override_debug_mcp_logging="${NOTION_LOCAL_OPS_DEBUG_MCP_LOGGING:-}"
  local override_graceful_shutdown_seconds="${NOTION_LOCAL_OPS_GRACEFUL_SHUTDOWN_SECONDS:-}"
  local override_label_prefix="${NOTION_LOCAL_OPS_LAUNCHD_LABEL_PREFIX:-}"
  local override_launchd_dir="${NOTION_LOCAL_OPS_LAUNCHD_DIR:-}"
  local override_launchd_log_dir="${NOTION_LOCAL_OPS_LAUNCHD_LOG_DIR:-}"
  local override_launchd_path="${NOTION_LOCAL_OPS_LAUNCHD_PATH:-}"

  load_env_file

  export NOTION_LOCAL_OPS_HOST="${override_host:-${NOTION_LOCAL_OPS_HOST:-127.0.0.1}}"
  export NOTION_LOCAL_OPS_PORT="${override_port:-${NOTION_LOCAL_OPS_PORT:-8766}}"
  export NOTION_LOCAL_OPS_WORKSPACE_ROOT="${override_workspace_root:-${NOTION_LOCAL_OPS_WORKSPACE_ROOT:-${ROOT_DIR}}}"
  export NOTION_LOCAL_OPS_STATE_DIR="${override_state_dir:-${NOTION_LOCAL_OPS_STATE_DIR:-${HOME}/.notion-local-ops-mcp}}"
  export NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG="${override_cloudflared_config:-${NOTION_LOCAL_OPS_CLOUDFLARED_CONFIG:-}}"
  export NOTION_LOCAL_OPS_TUNNEL_NAME="${override_tunnel_name:-${NOTION_LOCAL_OPS_TUNNEL_NAME:-}}"
  export NOTION_LOCAL_OPS_CODEX_COMMAND="${override_codex_command:-${NOTION_LOCAL_OPS_CODEX_COMMAND:-codex}}"
  export NOTION_LOCAL_OPS_CLAUDE_COMMAND="${override_claude_command:-${NOTION_LOCAL_OPS_CLAUDE_COMMAND:-claude}}"
  export NOTION_LOCAL_OPS_COMMAND_TIMEOUT="${override_command_timeout:-${NOTION_LOCAL_OPS_COMMAND_TIMEOUT:-120}}"
  export NOTION_LOCAL_OPS_DELEGATE_TIMEOUT="${override_delegate_timeout:-${NOTION_LOCAL_OPS_DELEGATE_TIMEOUT:-1800}}"
  export NOTION_LOCAL_OPS_DEBUG_MCP_LOGGING="${override_debug_mcp_logging:-${NOTION_LOCAL_OPS_DEBUG_MCP_LOGGING:-0}}"
  export NOTION_LOCAL_OPS_GRACEFUL_SHUTDOWN_SECONDS="${override_graceful_shutdown_seconds:-${NOTION_LOCAL_OPS_GRACEFUL_SHUTDOWN_SECONDS:-30}}"
  export NOTION_LOCAL_OPS_LAUNCHD_LABEL_PREFIX="${override_label_prefix:-${NOTION_LOCAL_OPS_LAUNCHD_LABEL_PREFIX:-com.notion-local-ops}}"
  export NOTION_LOCAL_OPS_LAUNCHD_DIR="${override_launchd_dir:-${NOTION_LOCAL_OPS_LAUNCHD_DIR:-${HOME}/Library/LaunchAgents}}"
  export NOTION_LOCAL_OPS_LAUNCHD_LOG_DIR="${override_launchd_log_dir:-${NOTION_LOCAL_OPS_LAUNCHD_LOG_DIR:-${HOME}/Library/Logs/notion-local-ops-mcp}}"
  export NOTION_LOCAL_OPS_LAUNCHD_PATH="${override_launchd_path:-${NOTION_LOCAL_OPS_LAUNCHD_PATH:-${CURRENT_SHELL_PATH}}}"

  if [[ -n "${override_auth_token}" ]]; then
    export NOTION_LOCAL_OPS_AUTH_TOKEN="${override_auth_token}"
  fi
}

mcp_label() {
  printf '%s.mcp\n' "${NOTION_LOCAL_OPS_LAUNCHD_LABEL_PREFIX}"
}

cloudflared_label() {
  printf '%s.cloudflared\n' "${NOTION_LOCAL_OPS_LAUNCHD_LABEL_PREFIX}"
}

launchctl_target() {
  local label="$1"
  printf 'gui/%s/%s\n' "${UID}" "${label}"
}

plist_path_for_label() {
  local label="$1"
  printf '%s/%s.plist\n' "${NOTION_LOCAL_OPS_LAUNCHD_DIR}" "${label}"
}

---
name: notion-local-ops-operator
description: Use when working inside notion-local-ops-mcp on macOS startup, launchd keepalive, rolling reload, cloudflared tunnel status, or /mcp connection failures from Notion.
---

# notion-local-ops operator

## Overview

This project has two runtime modes on macOS:

- `./scripts/dev-tunnel.sh` for foreground dev sessions
- launchd-managed services for long-lived local MCP + cloudflared keepalive

Prefer launchd when the goal is “stay up even if a shell/tmux pane dies”.

## Quick reference

- Install persistent services: `./scripts/install-launchd.sh`
- Check service + endpoint status: `./scripts/launchd-status.sh`
- Reload Python code without dropping the tunnel: `./scripts/launchd-reload.sh`
- Force restart after dependency/config changes: `./scripts/launchd-restart.sh all`
- Remove launchd services: `./scripts/uninstall-launchd.sh`

## Operational rules

- Keep the MCP supervisor and `cloudflared` as separate launchd services.
- Treat `launchd-reload.sh` as the default code-update path; it sends `HUP` to the supervisor so a fresh child server becomes ready before the old one drains.
- Use `launchd-restart.sh mcp` after `.venv` / dependency changes.
- Use `launchd-restart.sh cloudflared` after tunnel config changes.
- If install fails because the port is already bound, stop manual `dev-tunnel.sh` processes first.

## Debug order

1. `./scripts/launchd-status.sh`
2. Check local `http://127.0.0.1:8766/mcp`
3. Check public `https://<hostname>/mcp` if the tunnel config has a hostname
4. Inspect logs under `~/Library/Logs/notion-local-ops-mcp/`

## Common traps

- `dev-tunnel.sh` is not a durable keepalive service; closing the wrapper shell can still take everything down.
- launchd plists live under `~/Library/LaunchAgents/`; do not commit installed plist artifacts back into the repo.
- launchd gets a minimal environment. Always set runtime env vars through `.env` or the install-time render path, not by assuming your interactive shell exports them.

"""IP whitelist ASGI middleware.

Blocks requests from IPs not in the configured allowlist. Supports:
- Static CIDR/IP entries via ``NOTION_LOCAL_OPS_ALLOWED_IPS``.
- Dynamic IP list fetched from a URL via ``NOTION_LOCAL_OPS_ALLOWED_IPS_URL``
  (e.g. https://openai.com/chatgpt-connectors.json). The list is refreshed
  every ``NOTION_LOCAL_OPS_ALLOWED_IPS_REFRESH_SECONDS`` seconds.

When both env vars are empty the middleware is a no-op (all traffic allowed).

IP detection priority:
1. ``Cf-Connecting-Ip`` header (injected by Cloudflare tunnel, not spoofable).
2. ASGI ``scope["client"]`` (direct connection IP).
"""

from __future__ import annotations

import ipaddress
import json
import logging
import threading
import time
from typing import Any
from urllib.request import urlopen, Request
from urllib.error import URLError

from starlette.datastructures import Headers

logger = logging.getLogger("notion_local_ops_mcp.ip_whitelist")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(levelname)s:     %(name)s - %(message)s")
    )
    logger.addHandler(_handler)
    logger.setLevel(logging.INFO)

Network = ipaddress.IPv4Network | ipaddress.IPv6Network
Address = ipaddress.IPv4Address | ipaddress.IPv6Address


def parse_static_ips(raw: str) -> list[Network]:
    """Parse comma-separated IPs / CIDRs into a list of networks."""
    networks: list[Network] = []
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        try:
            networks.append(ipaddress.ip_network(entry, strict=False))
        except ValueError:
            logger.warning("Ignoring invalid IP/CIDR in ALLOWED_IPS: %s", entry)
    return networks


def fetch_remote_ips(url: str, timeout: float = 15) -> list[Network]:
    """Fetch a remote IP list. Supports two formats:

    1. OpenAI-style JSON: ``{"prefixes": [{"ipv4Prefix": "..."}, {"ipv6Prefix": "..."}]}``
    2. Plain text: one CIDR per line.
    """
    networks: list[Network] = []
    try:
        req = Request(url, headers={"User-Agent": "notion-local-ops-mcp/ip-whitelist"})
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8")
    except (URLError, OSError, UnicodeDecodeError) as exc:
        logger.error("Failed to fetch remote IP list from %s: %s", url, exc)
        return networks

    # Try JSON first.
    try:
        data = json.loads(body)
        if isinstance(data, dict) and "prefixes" in data:
            for item in data["prefixes"]:
                for key in ("ipv4Prefix", "ipv6Prefix", "ip_prefix", "prefix"):
                    cidr = item.get(key)
                    if cidr:
                        try:
                            networks.append(ipaddress.ip_network(cidr, strict=False))
                        except ValueError:
                            pass
            return networks
    except (json.JSONDecodeError, TypeError):
        pass

    # Fallback: plain-text, one CIDR per line.
    for line in body.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            try:
                networks.append(ipaddress.ip_network(line, strict=False))
            except ValueError:
                pass
    return networks


class _RemoteIPCache:
    """Thread-safe cache that periodically refreshes a remote IP list."""

    def __init__(self, url: str, refresh_seconds: int) -> None:
        self._url = url
        self._refresh_seconds = max(refresh_seconds, 60)
        self._networks: list[Network] = []
        self._lock = threading.Lock()
        self._last_fetch: float = 0
        # Eager first fetch (blocking).
        self._refresh()

    @property
    def networks(self) -> list[Network]:
        now = time.monotonic()
        if now - self._last_fetch >= self._refresh_seconds:
            # Non-blocking refresh in background thread.
            threading.Thread(target=self._refresh, daemon=True).start()
        with self._lock:
            return list(self._networks)

    def _refresh(self) -> None:
        fetched = fetch_remote_ips(self._url)
        if fetched:
            with self._lock:
                self._networks = fetched
            logger.info(
                "Refreshed %d remote IP ranges from %s", len(fetched), self._url
            )
        else:
            logger.warning("Remote fetch returned empty; keeping previous %d ranges.", len(self._networks))
        self._last_fetch = time.monotonic()


def _client_ip_from_scope(scope: dict[str, Any]) -> str:
    """Extract the best client IP from an ASGI scope."""
    headers = Headers(raw=scope.get("headers", []))
    # Cf-Connecting-Ip is injected by Cloudflare and cannot be spoofed when
    # traffic goes through a CF tunnel.
    cf_ip = headers.get("cf-connecting-ip", "").strip()
    if cf_ip:
        return cf_ip
    # Fallback: direct ASGI client IP.
    client = scope.get("client") or ("", 0)
    return client[0] if isinstance(client, tuple) else str(client)


def _ip_in_networks(ip_str: str, networks: list[Network]) -> bool:
    try:
        addr = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    return any(addr in net for net in networks)


class IPWhitelistMiddleware:
    """ASGI middleware that rejects requests from IPs not in the allowlist.

    When ``static_networks`` and ``remote_cache`` are both empty, the
    middleware is a transparent pass-through (all traffic allowed).
    """

    def __init__(
        self,
        app: Any,
        *,
        static_networks: list[Network] | None = None,
        remote_cache: _RemoteIPCache | None = None,
    ) -> None:
        self.app = app
        self._static = static_networks or []
        self._remote = remote_cache
        self._enabled = bool(self._static or self._remote)

    @property
    def enabled(self) -> bool:
        return self._enabled

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http" or not self._enabled:
            await self.app(scope, receive, send)
            return

        client_ip = _client_ip_from_scope(scope)

        # Log real IP for every HTTP request.
        headers = Headers(raw=scope.get("headers", []))
        direct_ip = (scope.get("client") or ("", 0))[0]
        cf_ip = headers.get("cf-connecting-ip", "").strip()
        method = scope.get("method", "?")
        path = scope.get("path", "?")
        if cf_ip and cf_ip != direct_ip:
            logger.info(
                "%s %s  real_ip=%s  direct_ip=%s",
                method, path, cf_ip, direct_ip,
            )
        else:
            logger.info("%s %s  client_ip=%s", method, path, client_ip)

        # Check static list first (fast path).
        if client_ip and _ip_in_networks(client_ip, self._static):
            await self.app(scope, receive, send)
            return

        # Check remote list.
        if self._remote and client_ip:
            remote_nets = self._remote.networks
            if _ip_in_networks(client_ip, remote_nets):
                await self.app(scope, receive, send)
                return

        logger.warning("BLOCKED %s %s  client_ip=%s (not in allowlist)", method, path, client_ip)
        await send({
            "type": "http.response.start",
            "status": 403,
            "headers": [
                [b"content-type", b"application/json"],
                [b"access-control-allow-origin", b"*"],
            ],
        })
        await send({
            "type": "http.response.body",
            "body": b'{"error":"ip_not_allowed","message":"Your IP address is not in the allowlist."}',
        })


def build_ip_whitelist_middleware(
    allowed_ips: str,
    allowed_ips_url: str,
    refresh_seconds: int,
) -> dict[str, Any]:
    """Build kwargs for ``IPWhitelistMiddleware``. Returns empty dict if disabled."""
    static = parse_static_ips(allowed_ips)
    remote: _RemoteIPCache | None = None
    if allowed_ips_url.strip():
        remote = _RemoteIPCache(allowed_ips_url.strip(), refresh_seconds)
    if not static and not remote:
        return {}
    return {"static_networks": static, "remote_cache": remote}

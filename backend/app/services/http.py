from __future__ import annotations

import asyncio
from typing import Any

import httpx


async def request_with_retry(
    client: httpx.AsyncClient,
    method: str,
    url: str,
    **kwargs: Any,
) -> httpx.Response:
    """Retry only transient transport, throttling, and server failures."""
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            response = await client.request(method, url, **kwargs)
            if response.status_code != 429 and response.status_code < 500:
                response.raise_for_status()
                return response
            response.raise_for_status()
        except (httpx.TransportError, httpx.HTTPStatusError) as exc:
            last_error = exc
            if isinstance(exc, httpx.HTTPStatusError):
                code = exc.response.status_code
                if code != 429 and code < 500:
                    raise
            if attempt < 2:
                retry_after = None
                if isinstance(exc, httpx.HTTPStatusError):
                    retry_after = exc.response.headers.get("Retry-After")
                delay = min(float(retry_after), 5.0) if retry_after else 0.5 * (2**attempt)
                await asyncio.sleep(delay)
    assert last_error is not None
    raise last_error

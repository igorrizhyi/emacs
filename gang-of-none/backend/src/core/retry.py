"""Retry with exponential backoff for ACP session errors."""

from __future__ import annotations

import asyncio
import re
from collections.abc import Awaitable, Callable
from typing import TypeVar

import structlog

logger = structlog.get_logger(__name__)

_RETRYABLE_PATTERNS = re.compile(
    r"no capacity|500|503|overloaded|temporarily unavailable",
    re.IGNORECASE,
)

T = TypeVar("T")


def is_retryable_error(error_msg: str) -> bool:
    """Return True if *error_msg* matches a known transient-error pattern."""
    return bool(_RETRYABLE_PATTERNS.search(error_msg))


async def retry_with_backoff(
    coro_factory: Callable[[], Awaitable[T]],
    backoff_seconds: list[float],
    description: str = "operation",
) -> T:
    """Call *coro_factory* with retries on transient ``RuntimeError``s.

    *coro_factory* is called (not awaited) to produce a fresh coroutine on
    each attempt.  Only ``RuntimeError`` whose message satisfies
    ``is_retryable_error`` triggers a retry; all other exceptions propagate
    immediately.

    ``backoff_seconds`` controls both the number of retries and the delay
    before each retry (element 0 is the delay before the *second* attempt,
    etc.).  The total number of attempts is ``len(backoff_seconds) + 1``.
    """
    max_attempts = len(backoff_seconds) + 1
    for attempt in range(1, max_attempts + 1):
        try:
            return await coro_factory()
        except RuntimeError as exc:
            if not is_retryable_error(str(exc)):
                raise
            if attempt == max_attempts:
                raise
            delay = backoff_seconds[attempt - 1]
            logger.warning(
                "retryable_error",
                description=description,
                attempt=attempt,
                max_attempts=max_attempts,
                delay=delay,
                error=str(exc),
            )
            await asyncio.sleep(delay)

    # Unreachable, but keeps type checkers happy.
    raise RuntimeError(f"{description}: all {max_attempts} attempts exhausted")  # pragma: no cover

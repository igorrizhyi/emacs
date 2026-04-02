"""Retry utilities for transient errors (capacity, rate-limits)."""

from __future__ import annotations

import asyncio
import re
from collections.abc import Awaitable, Callable
from typing import TypeVar

import structlog

logger = structlog.get_logger()

# Patterns that indicate a transient, retryable error.
RETRYABLE_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"(?i)no capacity available"),
    re.compile(r"(?i)rate.?limit"),
    re.compile(r"(?i)overloaded"),
    re.compile(r"(?i)503"),
    re.compile(r"(?i)too many requests"),
]

T = TypeVar("T")


def is_retryable_error(message: str) -> bool:
    """Return True if *message* matches a known transient-error pattern."""
    return any(pat.search(message) for pat in RETRYABLE_PATTERNS)


async def retry_with_backoff(
    fn: Callable[[], Awaitable[T]],
    *,
    max_attempts: int = 3,
    base_delay: float = 1.0,
    backoff_factor: float = 2.0,
) -> T:
    """Call *fn* up to *max_attempts* times, retrying on retryable errors.

    Uses exponential backoff between attempts.  Non-retryable errors are
    re-raised immediately.
    """
    last_exc: Exception | None = None
    delay = base_delay

    for attempt in range(1, max_attempts + 1):
        try:
            return await fn()
        except Exception as exc:
            if not is_retryable_error(str(exc)):
                raise
            last_exc = exc
            if attempt < max_attempts:
                logger.warning(
                    "retry.backoff",
                    attempt=attempt,
                    max_attempts=max_attempts,
                    delay=delay,
                    error=str(exc),
                )
                await asyncio.sleep(delay)
                delay *= backoff_factor

    # All attempts exhausted — re-raise the last error.
    assert last_exc is not None
    raise last_exc

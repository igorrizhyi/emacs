"""Tests for the retry module — is_retryable_error and retry_with_backoff."""

from unittest.mock import AsyncMock, patch

import pytest

from src.core.retry import is_retryable_error, retry_with_backoff


class TestIsRetryableError:
    def test_matches_capacity_error(self):
        assert is_retryable_error("No capacity available") is True

    def test_matches_rate_limit(self):
        assert is_retryable_error("Rate limit exceeded") is True

    def test_matches_overloaded(self):
        assert is_retryable_error("Server overloaded, try again") is True

    def test_matches_503(self):
        assert is_retryable_error("HTTP 503 Service Unavailable") is True

    def test_no_match_invalid_api_key(self):
        assert is_retryable_error("Invalid API key") is False

    def test_no_match_permission_denied(self):
        assert is_retryable_error("Permission denied") is False

    def test_no_match_empty(self):
        assert is_retryable_error("") is False


class TestRetryWithBackoff:
    @patch("src.core.retry.asyncio.sleep", new_callable=AsyncMock)
    async def test_succeeds_first_try(self, mock_sleep: AsyncMock):
        fn = AsyncMock(return_value="ok")
        result = await retry_with_backoff(fn, max_attempts=3)
        assert result == "ok"
        fn.assert_awaited_once()
        mock_sleep.assert_not_awaited()

    @patch("src.core.retry.asyncio.sleep", new_callable=AsyncMock)
    async def test_retries_on_capacity_error(self, mock_sleep: AsyncMock):
        fn = AsyncMock(
            side_effect=[
                RuntimeError("No capacity available"),
                RuntimeError("No capacity available"),
                "success",
            ]
        )
        result = await retry_with_backoff(fn, max_attempts=3, base_delay=0.1)
        assert result == "success"
        assert fn.await_count == 3
        assert mock_sleep.await_count == 2

    @patch("src.core.retry.asyncio.sleep", new_callable=AsyncMock)
    async def test_raises_non_retryable(self, mock_sleep: AsyncMock):
        fn = AsyncMock(side_effect=RuntimeError("Invalid API key"))
        with pytest.raises(RuntimeError, match="Invalid API key"):
            await retry_with_backoff(fn, max_attempts=3)
        fn.assert_awaited_once()
        mock_sleep.assert_not_awaited()

    @patch("src.core.retry.asyncio.sleep", new_callable=AsyncMock)
    async def test_exhausts_retries(self, mock_sleep: AsyncMock):
        fn = AsyncMock(side_effect=RuntimeError("No capacity available"))
        with pytest.raises(RuntimeError, match="No capacity available"):
            await retry_with_backoff(fn, max_attempts=3, base_delay=0.1)
        assert fn.await_count == 3
        assert mock_sleep.await_count == 2

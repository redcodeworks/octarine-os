"""The @ci.retry decorator: transient errors are retried, definitive answers are not,
the last error comes back with the attempt count.
"""

import pytest

import ci


class Transient(Exception):
    pass


class Definitive(Exception):
    pass


@pytest.fixture(autouse=True)
def no_waiting(monkeypatch):
    """Remove the retry pause so the tests do not wait."""
    monkeypatch.setenv("RETRY_DELAY", "0")


def flaky(fail_times, error=Transient):
    """Build a function that fails with `error` the first `fail_times` calls, then
    returns "ok".

    Returns the function, wrapped in the retry decorator for Transient, and the list
    that records each call.
    """
    calls = []

    @ci.retry(on=(Transient,))
    def fn():
        """Fail while calls remain in `fail_times`, then succeed."""
        calls.append(1)

        # fail on the first calls only
        if len(calls) <= fail_times:
            raise error(f"boom {len(calls)}")
        return "ok"

    return fn, calls


def test_transient_errors_are_retried_until_one_try_succeeds():
    """Transient errors are retried until a try succeeds."""
    fn, calls = flaky(2)
    assert fn() == "ok" and len(calls) == 3


def test_a_definitive_error_stops_at_once():
    """A definitive error is not retried: it propagates after one call."""
    fn, calls = flaky(5, error=Definitive)

    # the error is not Transient, so the decorator lets it through
    with pytest.raises(Definitive):
        fn()
    assert len(calls) == 1


def test_the_last_error_is_re_raised_with_the_attempt_count():
    """After the last try the original error comes back with the attempt count added."""
    fn, calls = flaky(99)

    # the message keeps the original text and gains the count
    with pytest.raises(Transient, match=r"boom 3 \(failed 3 attempts\)"):
        fn()
    assert len(calls) == 3


def test_attempts_and_the_waits_follow_the_arguments(monkeypatch):
    """The decorator's arguments set the number of tries and the pauses."""
    waits = []
    monkeypatch.setattr(ci.time, "sleep", waits.append)

    @ci.retry(on=(Transient,), attempts=4, delay=2)
    def always():
        """Always fail, to exhaust the tries."""
        raise Transient("x")

    # four tries with growing pauses
    with pytest.raises(Transient, match="failed 4 attempts"):
        always()
    assert waits == [2, 4, 6]  # the pause grows with the try number

    waits.clear()

    @ci.retry(on=(Transient,), attempts=3, delay=5, backoff=False)
    def same():
        """Always fail, to exhaust the tries with a constant pause."""
        raise Transient("x")

    # three tries with the same pause each time
    with pytest.raises(Transient):
        same()
    assert waits == [5, 5]

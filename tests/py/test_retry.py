"""The @ci.retry decorator: transient errors are retried, definitive answers are not, the last error comes back with the attempt count."""

import pytest

import ci


class Transient(Exception):
    pass


class Definitive(Exception):
    pass


@pytest.fixture(autouse=True)
def no_waiting(monkeypatch):
    monkeypatch.setenv("RETRY_DELAY", "0")


def flaky(fail_times, error=Transient):
    calls = []

    @ci.retry(on=(Transient,))
    def fn():
        calls.append(1)
        if len(calls) <= fail_times:
            raise error(f"boom {len(calls)}")
        return "ok"

    return fn, calls


def test_transient_errors_are_retried_until_one_try_succeeds():
    fn, calls = flaky(2)
    assert fn() == "ok" and len(calls) == 3


def test_a_definitive_error_stops_at_once():
    fn, calls = flaky(5, error=Definitive)
    with pytest.raises(Definitive):
        fn()
    assert len(calls) == 1


def test_the_last_error_is_re_raised_with_the_attempt_count():
    fn, calls = flaky(99)
    with pytest.raises(Transient, match=r"boom 3 \(failed 3 attempts\)"):
        fn()
    assert len(calls) == 3


def test_attempts_and_the_waits_follow_the_arguments(monkeypatch):
    waits = []
    monkeypatch.setattr(ci.time, "sleep", waits.append)

    @ci.retry(on=(Transient,), attempts=4, delay=2)
    def always():
        raise Transient("x")

    with pytest.raises(Transient, match="failed 4 attempts"):
        always()
    assert waits == [2, 4, 6]  # the pause grows with the try number

    waits.clear()

    @ci.retry(on=(Transient,), attempts=3, delay=5, backoff=False)
    def same():
        raise Transient("x")

    with pytest.raises(Transient):
        same()
    assert waits == [5, 5]

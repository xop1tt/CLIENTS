import httpx
import pytest

from leadgen.core.http import BudgetExceeded, HttpError, SourceHttp

URL = "https://example.test/x"


def mk(store, **kw):
    sleeps = []
    h = SourceHttp("src", store, min_interval=0, base_delay=1, sleep=sleeps.append, **kw)
    return h, sleeps


def test_retry_with_exponential_backoff(store, no_network):
    route = no_network.get(URL).mock(side_effect=[httpx.Response(503), httpx.Response(502), httpx.Response(200, text="ok")])
    h, sleeps = mk(store, max_attempts=4)
    assert h.get(URL).text == "ok"
    assert route.call_count == 3
    assert sleeps[0] >= 1 and sleeps[1] >= 2          # 1с, 2с (+джиттер)
    assert store.request_stats()[0] == {"source": "src", "requests": 3, "errors": 2}


def test_retry_after_is_respected(store, no_network):
    no_network.get(URL).mock(side_effect=[httpx.Response(429, headers={"Retry-After": "7"}), httpx.Response(200)])
    h, sleeps = mk(store)
    h.get(URL)
    assert 7.0 in sleeps


def test_non_transient_error_not_retried(store, no_network):
    route = no_network.get(URL).mock(return_value=httpx.Response(404))
    h, _ = mk(store)
    with pytest.raises(HttpError) as e:
        h.get(URL)
    assert route.call_count == 1 and e.value.status == 404 and not e.value.transient


def test_timeouts_exhaust_attempts(store, no_network):
    no_network.get(URL).mock(side_effect=httpx.ConnectTimeout("t"))
    h, _ = mk(store, max_attempts=3)
    with pytest.raises(HttpError) as e:
        h.get(URL)
    assert e.value.transient


def test_budget_per_run_and_per_day(store, no_network):
    no_network.get(URL).mock(return_value=httpx.Response(200))
    h, _ = mk(store, max_requests_per_run=2)
    h.get(URL), h.get(URL)
    with pytest.raises(BudgetExceeded):
        h.get(URL)
    h2, _ = mk(store, max_requests_per_day=2)
    with pytest.raises(BudgetExceeded):
        h2.get(URL)  # уже 2 запроса сегодня у источника src

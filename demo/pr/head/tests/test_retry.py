from webhooks.retry import backoff_delays


def test_delays_never_exceed_the_cap():
    delays = list(backoff_delays(10, base=1, cap=8))
    assert all(0 <= d <= 8 for d in delays)


def test_one_delay_per_attempt():
    assert len(list(backoff_delays(4))) == 4

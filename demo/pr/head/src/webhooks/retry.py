import random


def backoff_delays(attempts, base=0.5, cap=30.0):
    """Delays between attempts: exponential, capped, with full jitter."""
    for attempt in range(attempts):
        ceiling = min(cap, base * 2 ** attempt)
        yield random.uniform(0, ceiling)

import time


class TokenBucket:
    """Allow `rate` requests per second, with bursts of up to `capacity`."""

    def __init__(self, rate, capacity):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
        self.updated = time.monotonic()

    def _refill(self):
        now = time.monotonic()
        elapsed = now - self.updated
        self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
        self.updated = now

    def allow(self, cost=1):
        self._refill()
        if self.tokens >= cost:
            self.tokens -= cost
            return True
        return False

    def wait_time(self, cost=1):
        self._refill()
        missing = cost - self.tokens
        return max(0.0, missing / self.rate)


limiter = TokenBucket(rate=5, capacity=10)

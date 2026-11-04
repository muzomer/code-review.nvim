import time

import requests

from .models import Webhook
from .retry import backoff_delays


def deliver(hook: Webhook, payload: dict) -> bool:
    response = requests.post(hook.url, json=payload, timeout=5)
    return response.ok


def deliver_with_retry(hook: Webhook, payload: dict, attempts: int = 5) -> bool:
    for delay in backoff_delays(attempts):
        if deliver(hook, payload):
            return True
        time.sleep(delay)
    return False


def dispatch(hooks, payload):
    failed = []
    for hook in hooks:
        if not deliver_with_retry(hook, payload):
            failed.append(hook)
    return failed

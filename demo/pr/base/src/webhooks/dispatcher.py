import requests

from .models import Webhook


def deliver(hook: Webhook, payload: dict) -> bool:
    response = requests.post(hook.url, json=payload, timeout=5)
    return response.ok


def dispatch(hooks, payload):
    failed = []
    for hook in hooks:
        if not deliver(hook, payload):
            failed.append(hook)
    return failed

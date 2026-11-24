"""transfer: moves money. Calls accounts (debit, then credit) and then
notification (send an SMS).

RESILIENT=false (default): the "first version" a developer writes. No timeout,
no retry, no circuit breaker. This is the code the problem labs break.

RESILIENT=true: the same calls wrapped in a timeout, retries and a circuit
breaker, using Python libraries. This is the "fix it in the application" lab.
"""
import os
import time
import uuid

import requests
from flask import jsonify, request

from common import POD, create_app, forward_headers, log

app = create_app()

ACCOUNTS = os.environ.get("ACCOUNTS_URL", "http://accounts:8080")
NOTIFICATION = os.environ.get("NOTIFICATION_URL", "http://notification:8080")
RESILIENT = os.environ.get("RESILIENT", "false").lower() == "true"


# ---------------------------------------------------------------------------
# Version 1: the naive call. requests waits FOREVER if the server never
# answers, and a single failed call fails the whole transfer.
# ---------------------------------------------------------------------------
def naive_call(method, url, json_body=None):
    return requests.request(method, url, json=json_body,
                            headers=forward_headers())


# ---------------------------------------------------------------------------
# Version 2: the application-level fix. 3 libraries, about 30 lines, and it
# protects ONLY this one Python service.
# ---------------------------------------------------------------------------
import pybreaker                                   # circuit breaker
from tenacity import (retry, retry_if_exception_type,  # retries
                      stop_after_attempt, wait_fixed)


class RetryableError(Exception):
    """A 503 or a network error: worth trying again."""


# One breaker per downstream service. After 5 failures in a row it "opens"
# and fails fast for 30 seconds instead of calling a sick service.
breakers = {
    "accounts": pybreaker.CircuitBreaker(fail_max=5, reset_timeout=30),
    "notification": pybreaker.CircuitBreaker(fail_max=5, reset_timeout=30),
}


@retry(retry=retry_if_exception_type(RetryableError),
       stop=stop_after_attempt(3), wait=wait_fixed(0.2), reraise=True)
def _one_try(method, url, json_body):
    try:
        resp = requests.request(method, url, json=json_body,
                                headers=forward_headers(),
                                timeout=(1, 2))   # 1 s to connect, 2 s to answer
    except requests.exceptions.ReadTimeout:
        raise                                     # slow: do not retry, give up
    except requests.exceptions.ConnectionError as err:
        raise RetryableError(str(err)) from err   # could not connect: try again
    if resp.status_code == 503:
        raise RetryableError(f"503 from {url}")
    return resp


def resilient_call(method, url, json_body=None):
    name = "accounts" if url.startswith(ACCOUNTS) else "notification"
    return breakers[name].call(_one_try, method, url, json_body)


def call(method, url, json_body=None):
    if RESILIENT:
        return resilient_call(method, url, json_body)
    return naive_call(method, url, json_body)


# ---------------------------------------------------------------------------
@app.post("/api/transfer")
def transfer():
    started = time.time()
    body = request.get_json(force=True, silent=True) or {}
    src, dst = body.get("from"), body.get("to")
    amount = int(body.get("amount", 0))
    tid = "TRF-" + uuid.uuid4().hex[:8]

    def answer(status, http_code, **extra):
        ms = int((time.time() - started) * 1000)
        log(event="transfer", id=tid, status=status, ms=ms,
            src=src, dst=dst, amount=amount, **extra)
        return jsonify(id=tid, status=status, ms=ms, transfer_pod=POD,
                       **extra), http_code

    # 1. Debit the sender
    try:
        r = call("POST", f"{ACCOUNTS}/api/accounts/{src}/debit",
                 {"amount": amount})
    except Exception as err:                      # noqa: BLE001
        return answer("FAILED", 503, step="debit", error=str(err))
    if r.status_code != 200:
        return answer("FAILED", r.status_code, step="debit", error=r.text)

    # 2. Credit the receiver. If it fails, give the money back.
    try:
        r = call("POST", f"{ACCOUNTS}/api/accounts/{dst}/credit",
                 {"amount": amount})
        ok = r.status_code == 200
        why = r.text
    except Exception as err:                      # noqa: BLE001
        ok, why = False, str(err)
    if not ok:
        try:
            r = call("POST", f"{ACCOUNTS}/api/accounts/{src}/credit",
                     {"amount": amount})
            refund = "done" if r.status_code == 200 else "FAILED, money is lost"
        except Exception:                         # noqa: BLE001
            refund = "FAILED, money is lost"
        return answer("FAILED", 503, step="credit", error=why, refund=refund)

    # 3. Send the SMS. Best effort: a failed SMS does not fail the transfer.
    try:
        call("POST", f"{NOTIFICATION}/api/notify",
             {"to": src, "text": f"{amount} sent to {dst}, ref {tid}"})
        sms = "sent"
    except Exception:                             # noqa: BLE001
        sms = "skipped"

    return answer("COMPLETED", 200, sms=sms)

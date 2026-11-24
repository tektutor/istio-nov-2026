"""Code shared by all 4 Netbanking services.

- one JSON log line per request
- /healthz and /readyz for Kubernetes probes
- /admin/chaos to make ONE pod slow or failing (used in the problem labs)
- forward_headers(): copies tracing and routing headers to outgoing calls
"""
import json
import os
import random
import sys
import time

from flask import Flask, g, jsonify, request

SERVICE = os.environ.get("SERVICE", "unknown")
VERSION = os.environ.get("VERSION", "v1")
POD = os.environ.get("HOSTNAME", "local")

# Chaos settings live in the memory of this one process (one pod).
chaos = {
    "delay_ms": int(os.environ.get("DELAY_MS", "0")),
    "fail_rate": float(os.environ.get("FAIL_RATE", "0")),
}

# Headers that must travel from the incoming request to every outgoing call.
PROPAGATE = [
    "x-request-id", "traceparent", "tracestate",
    "x-b3-traceid", "x-b3-spanid", "x-b3-parentspanid", "x-b3-sampled",
    "x-customer-tier",
]


def log(**fields):
    fields = {"time": time.strftime("%H:%M:%S"), "service": SERVICE,
              "version": VERSION, "pod": POD, **fields}
    print(json.dumps(fields), file=sys.stdout, flush=True)


def forward_headers():
    return {h: request.headers[h] for h in PROPAGATE if h in request.headers}


def caller_identity():
    """With Istio mTLS, the sidecar adds X-Forwarded-Client-Cert.
    Without a mesh this header is missing, so we only know an IP address."""
    xfcc = request.headers.get("X-Forwarded-Client-Cert", "")
    if "URI=" in xfcc:
        return xfcc.split("URI=")[-1].split(";")[0]
    return "unknown"


def create_app():
    app = Flask(SERVICE)

    @app.before_request
    def inject_chaos():
        g.start = time.time()
        if request.path.startswith(("/admin", "/healthz", "/readyz")):
            return None
        if chaos["delay_ms"]:
            time.sleep(chaos["delay_ms"] / 1000)
        if chaos["fail_rate"] and random.random() < chaos["fail_rate"]:
            return jsonify(error=f"{SERVICE} pod {POD} failed (chaos)"), 503
        return None

    @app.after_request
    def log_request(resp):
        if not request.path.startswith(("/healthz", "/readyz")):
            log(event="request", method=request.method, path=request.path,
                status=resp.status_code,
                ms=int((time.time() - g.start) * 1000),
                client_ip=request.remote_addr, caller=caller_identity())
        return resp

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok")

    @app.get("/readyz")
    def readyz():
        return jsonify(status="ready")

    @app.route("/admin/chaos", methods=["GET", "POST"])
    def admin_chaos():
        if request.method == "POST":
            body = request.get_json(force=True, silent=True) or {}
            if "delay_ms" in body:
                chaos["delay_ms"] = int(body["delay_ms"])
            if "fail_rate" in body:
                chaos["fail_rate"] = float(body["fail_rate"])
            log(event="chaos", **chaos)
        return jsonify(pod=POD, **chaos)

    return app

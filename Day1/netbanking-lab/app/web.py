"""web: the page customers open. Shows balances (from accounts) and sends
transfers (to transfer). Like transfer, its calls have no timeout."""
import html
import os

import requests
from flask import jsonify, redirect, request

from common import POD, VERSION, create_app, forward_headers

app = create_app()

ACCOUNTS = os.environ.get("ACCOUNTS_URL", "http://accounts:8080")
TRANSFER = os.environ.get("TRANSFER_URL", "http://transfer:8080")


def fetch_accounts():
    r = requests.get(f"{ACCOUNTS}/api/accounts", headers=forward_headers())
    r.raise_for_status()
    return r.json()


@app.get("/api/summary")
def summary():
    try:
        data = fetch_accounts()
    except Exception as err:                      # noqa: BLE001
        return jsonify(web_pod=POD, error=str(err)), 503
    return jsonify(web_pod=POD, web_version=VERSION,
                   accounts_pod=data["pod"], accounts_version=data["version"],
                   total_balance=sum(a["balance"] for a in data["accounts"]),
                   accounts=data["accounts"])


@app.post("/api/transfer")
def api_transfer():
    body = request.get_json(force=True, silent=True) or {}
    try:
        r = requests.post(f"{TRANSFER}/api/transfer", json=body,
                          headers=forward_headers())
    except Exception as err:                      # noqa: BLE001
        return jsonify(status="FAILED", error=str(err)), 503
    return r.content, r.status_code, {"Content-Type": "application/json"}


@app.post("/transfer")
def form_transfer():
    body = {"from": request.form.get("from"), "to": request.form.get("to"),
            "amount": request.form.get("amount", "0")}
    try:
        r = requests.post(f"{TRANSFER}/api/transfer", json=body,
                          headers=forward_headers())
        msg = f"Transfer {r.json().get('id')}: {r.json().get('status')}"
    except Exception as err:                      # noqa: BLE001
        msg = f"Transfer failed: {err}"
    return redirect(f"/?msg={html.escape(msg)}", code=302)


@app.get("/")
def page():
    msg = html.escape(request.args.get("msg", ""))
    try:
        data = fetch_accounts()
        rows = "".join(
            f"<tr><td>{a['account']}</td><td>{html.escape(a['holder'])}</td>"
            f"<td style='text-align:right'>{a['balance']:,}</td>"
            f"<td>{a.get('ifsc', '')}</td></tr>"
            for a in data["accounts"])
        total = sum(a["balance"] for a in data["accounts"])
        info = f"accounts {data['version']} on {data['pod']}"
    except Exception as err:                      # noqa: BLE001
        rows, total, info = "", 0, f"accounts unavailable: {html.escape(str(err))}"
    return f"""<!doctype html><html><head><title>Netbanking</title>
<style>body{{font-family:sans-serif;margin:2em;max-width:720px}}
table{{border-collapse:collapse;width:100%}}td,th{{border:1px solid #ccc;padding:6px}}
.msg{{background:#eef;padding:8px;margin:1em 0}}</style></head><body>
<h1>Netbanking</h1>
<p>web {VERSION} on {POD} &middot; {info}</p>
{f"<div class='msg'>{msg}</div>" if msg else ""}
<table><tr><th>Account</th><th>Holder</th><th>Balance (INR)</th><th>IFSC</th></tr>
{rows}<tr><th colspan=2>Total</th><th style='text-align:right'>{total:,}</th><th></th></tr></table>
<h2>Transfer money</h2>
<form method=post action=/transfer>
From <select name=from><option>ACC-1001</option><option>ACC-1002</option><option>ACC-1003</option></select>
To <select name=to><option>ACC-1002</option><option>ACC-1001</option><option>ACC-1003</option></select>
Amount <input name=amount value=500 size=8> <button>Send</button></form>
</body></html>"""

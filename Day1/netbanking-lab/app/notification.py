"""notification: sends an SMS for every transfer (here it only logs it)."""
from flask import jsonify, request

from common import POD, create_app, log

app = create_app()


@app.post("/api/notify")
def notify():
    body = request.get_json(force=True, silent=True) or {}
    log(event="sms", to=body.get("to"), text=body.get("text"))
    return jsonify(status="sent", pod=POD)

"""accounts: owns the balances. Stores them in Redis (or in memory when
REDIS_HOST is empty, for laptop tests)."""
import os

from flask import jsonify, request

from common import POD, VERSION, create_app, log

app = create_app()

OPENING = {
    "ACC-1001": {"holder": "Kayal", "balance": 50000},
    "ACC-1002": {"holder": "Ranganathan", "balance": 25000},
    "ACC-1003": {"holder": "Nambi", "balance": 100000},
}

REDIS_HOST = os.environ.get("REDIS_HOST", "")

if REDIS_HOST:
    import redis
    db = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)
    for acc, data in OPENING.items():
        db.setnx(f"balance:{acc}", data["balance"])
    # Check and change the balance in ONE atomic step, so two parallel
    # debits cannot spend the same money.
    _move = db.register_script("""
        local bal = tonumber(redis.call('GET', KEYS[1]))
        local amt = tonumber(ARGV[1])
        if bal == nil then return -1 end
        if bal + amt < 0 then return -2 end
        return redis.call('INCRBY', KEYS[1], amt)
    """)

    def get_balance(acc):
        val = db.get(f"balance:{acc}")
        return None if val is None else int(val)

    def move(acc, amount):
        return int(_move(keys=[f"balance:{acc}"], args=[amount]))
else:
    memory = {acc: data["balance"] for acc, data in OPENING.items()}

    def get_balance(acc):
        return memory.get(acc)

    def move(acc, amount):
        if acc not in memory:
            return -1
        if memory[acc] + amount < 0:
            return -2
        memory[acc] += amount
        return memory[acc]


def account_view(acc):
    view = {"account": acc, "holder": OPENING[acc]["holder"],
            "balance": get_balance(acc)}
    if VERSION == "v2":
        # v2 is the "new release": it also shows the branch IFSC code.
        view["ifsc"] = "NETB0000123"
    return view


@app.get("/api/accounts")
def list_accounts():
    return jsonify(version=VERSION, pod=POD,
                   accounts=[account_view(a) for a in OPENING])


@app.get("/api/accounts/<acc>")
def one_account(acc):
    if acc not in OPENING:
        return jsonify(error="no such account"), 404
    return jsonify(version=VERSION, pod=POD, **account_view(acc))


def change(acc, amount, kind):
    body = request.get_json(force=True, silent=True) or {}
    amount = int(body.get("amount", 0))
    if amount <= 0:
        return jsonify(error="amount must be positive"), 400
    result = move(acc, -amount if kind == "debit" else amount)
    if result == -1:
        return jsonify(error="no such account"), 404
    if result == -2:
        return jsonify(error="insufficient funds"), 409
    log(event="ledger", kind=kind, account=acc, amount=amount, balance=result)
    return jsonify(account=acc, kind=kind, amount=amount, balance=result,
                   pod=POD, version=VERSION)


@app.post("/api/accounts/<acc>/debit")
def debit(acc):
    return change(acc, 0, "debit")


@app.post("/api/accounts/<acc>/credit")
def credit(acc):
    return change(acc, 0, "credit")

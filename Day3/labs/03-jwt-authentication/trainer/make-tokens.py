"""Trainer only: make the JWT key and the 3 lab tokens for Day 3, Lab 3.

Run it from the lab folder:
    python3 trainer/make-tokens.py
It writes kayal.jwt, expired.jwt and forged.jwt, and puts the matching public key
set (JWKS) into request-authentication.yaml. Needs: pip install pyjwt cryptography
The private keys exist only while the script runs, so nobody can make more tokens later.
"""
import base64
import json
import re
from datetime import datetime, timezone

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

ISSUER = "https://login.netbanking.tektutor.org"
AUDIENCE = "netbanking"
KID = "netbanking-2026"


def b64url_uint(value):
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def token(key, expires):
    claims = {
        "iss": ISSUER,
        "sub": "kayal",
        "aud": AUDIENCE,
        "account": "ACC-1001",
        "name": "Kayal",
        "iat": int(datetime(2026, 11, 1, tzinfo=timezone.utc).timestamp()),
        "exp": int(expires.timestamp()),
    }
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": KID})


trusted = rsa.generate_private_key(public_exponent=65537, key_size=2048)
untrusted = rsa.generate_private_key(public_exponent=65537, key_size=2048)

files = {
    "kayal.jwt": token(trusted, datetime(2030, 1, 1, tzinfo=timezone.utc)),
    "expired.jwt": token(trusted, datetime(2026, 1, 1, tzinfo=timezone.utc)),
    # Same kid and claims, but signed with a key the mesh does not trust
    "forged.jwt": token(untrusted, datetime(2030, 1, 1, tzinfo=timezone.utc)),
}
for name, value in files.items():
    with open(name, "w") as f:
        f.write(value + "\n")

numbers = trusted.public_key().public_numbers()
jwks = {"keys": [{"kty": "RSA", "kid": KID, "alg": "RS256", "use": "sig",
                  "n": b64url_uint(numbers.n), "e": b64url_uint(numbers.e)}]}
with open("request-authentication.yaml") as f:
    yaml = f.read()
yaml = re.sub(r'(jwks: \|\n\s+).*', lambda m: m.group(1) + json.dumps(jwks), yaml)
with open("request-authentication.yaml", "w") as f:
    f.write(yaml)
print("Wrote kayal.jwt, expired.jwt, forged.jwt and the JWKS in request-authentication.yaml")

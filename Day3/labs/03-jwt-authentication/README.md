# Day 3, Lab 3: End-user authentication with JWT

Workbook: *Istio Workbook Module 1: Why Netbanking Needs a Service Mesh*.
Run every command from this folder:

```bash
cd ~/istio-nov-2026/Day3/labs/03-jwt-authentication
```

## Files

- `authz-web.yaml`
- `expired.jwt`
- `forged.jwt`
- `kayal.jwt`
- `request-authentication.yaml`
- `trainer/make-tokens.py`

`kayal.jwt` is valid until 1 January 2030. `expired.jwt` has already expired.
`forged.jwt` is signed with a key the mesh does not trust.
Trainer: `python3 trainer/make-tokens.py` makes a new key, new tokens and a matching JWKS.

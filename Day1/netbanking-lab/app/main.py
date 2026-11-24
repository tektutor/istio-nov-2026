"""Entry point for gunicorn. The SERVICE variable picks which service runs:
web, transfer, accounts or notification."""
import importlib
import os

app = importlib.import_module(os.environ["SERVICE"]).app

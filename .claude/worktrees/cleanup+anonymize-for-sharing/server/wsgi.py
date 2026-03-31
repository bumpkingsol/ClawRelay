#!/usr/bin/env python3
"""Gunicorn entrypoint for the Flask receiver."""

import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).with_name('context-receiver.py')
SPEC = importlib.util.spec_from_file_location('context_receiver_app', MODULE_PATH)

if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load receiver module from {MODULE_PATH}")

MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
app = MODULE.app

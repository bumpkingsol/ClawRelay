"""Shared database utilities for Context Bridge server.

Provides encrypted SQLite connections via SQLCipher when available,
falling back to standard sqlite3 if SQLCipher is not installed.
"""

import os
import sqlite3
import hashlib
import logging

logger = logging.getLogger(__name__)

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/admin/clawd/data/context-bridge.db')

# Derive encryption key from the auth token + a fixed salt.
# This means there's only one secret to protect (.env token).
_AUTH_TOKEN = os.environ.get('CONTEXT_BRIDGE_TOKEN', '').strip()
_SALT = b'openclaw-context-bridge-db-key-v1'
DB_KEY = hashlib.pbkdf2_hmac('sha256', _AUTH_TOKEN.encode(), _SALT, 100_000).hex() if _AUTH_TOKEN else ''

_USE_SQLCIPHER = False

try:
    from pysqlcipher3 import dbapi2 as sqlcipher
    _USE_SQLCIPHER = True
    logger.info("SQLCipher available — database encryption enabled")
except ImportError:
    logger.info("SQLCipher not available — using standard sqlite3 (unencrypted)")


def get_db(db_path=None):
    """Get SQLite connection with WAL mode. Uses SQLCipher if available."""
    path = db_path or DB_PATH

    if _USE_SQLCIPHER and DB_KEY:
        db = sqlcipher.connect(path)
        db.execute(f"PRAGMA key = '{DB_KEY}'")
    else:
        db = sqlite3.connect(path)

    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
    db.row_factory = lambda cursor, row: {col[0]: row[idx] for idx, col in enumerate(cursor.description)}
    return db


def is_encrypted():
    """Return True if SQLCipher is active."""
    return _USE_SQLCIPHER and bool(DB_KEY)

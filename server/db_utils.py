"""Shared database utilities for Context Bridge server."""

import os
import sqlite3
import hashlib
import logging

logger = logging.getLogger(__name__)

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/user/clawrelay/data/context-bridge.db')
ALLOW_PLAINTEXT_DB_FOR_TESTS = os.environ.get(
    'CONTEXT_BRIDGE_ALLOW_PLAINTEXT_DB_FOR_TESTS', 'false'
).lower() == 'true'
REQUIRE_SQLCIPHER = os.environ.get(
    'CONTEXT_BRIDGE_REQUIRE_SQLCIPHER', 'true'
).lower() != 'false'

# Derive encryption key from a dedicated DB key when available, otherwise
# from the scoped auth secrets. This keeps encryption independent from any
# one client token while still allowing deterministic bootstrapping.
_DB_KEY_MATERIAL = os.environ.get('CONTEXT_BRIDGE_DB_KEY', '').strip()
if not _DB_KEY_MATERIAL:
    _DB_KEY_MATERIAL = "|".join(
        token
        for token in (
            os.environ.get('CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN', '').strip(),
            os.environ.get('CONTEXT_BRIDGE_HELPER_TOKEN', '').strip(),
            os.environ.get('CONTEXT_BRIDGE_AGENT_TOKEN', '').strip(),
        )
        if token
    )
_SALT = b'openclaw-context-bridge-db-key-v1'
DB_KEY = hashlib.pbkdf2_hmac('sha256', _DB_KEY_MATERIAL.encode(), _SALT, 100_000).hex() if _DB_KEY_MATERIAL else ''

_USE_SQLCIPHER = False

try:
    from pysqlcipher3 import dbapi2 as sqlcipher
    _USE_SQLCIPHER = True
    logger.info("SQLCipher available — database encryption enabled")
except ImportError:
    logger.info("SQLCipher not available — using standard sqlite3 (unencrypted)")


def validate_db_configuration():
    """Fail closed when production encryption requirements are not met."""
    if _USE_SQLCIPHER and DB_KEY:
        return
    if ALLOW_PLAINTEXT_DB_FOR_TESTS:
        logger.warning("Plaintext SQLite allowed by explicit test/dev override")
        return
    if REQUIRE_SQLCIPHER:
        raise RuntimeError(
            "SQLCipher is required for this deployment. "
            "Install pysqlcipher3 or explicitly set "
            "CONTEXT_BRIDGE_ALLOW_PLAINTEXT_DB_FOR_TESTS=true for non-production use."
        )


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

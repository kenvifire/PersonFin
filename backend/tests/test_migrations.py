"""Runs the real Alembic migrations (in a subprocess, against a throwaway
SQLite file) to check the schema they produce, independently of the
`Base.metadata.create_all` schema the rest of the suite uses."""

import os
import subprocess
import sys
from pathlib import Path

import pytest
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

BACKEND_DIR = Path(__file__).resolve().parent.parent


def _alembic(database_url: str, *args: str) -> None:
    env = {**os.environ, "DATABASE_URL": database_url}
    subprocess.run(
        [sys.executable, "-m", "alembic", *args],
        cwd=BACKEND_DIR,
        env=env,
        check=True,
        capture_output=True,
    )


def _indexes(engine) -> dict[str, bool]:
    return {index["name"]: bool(index["unique"]) for index in inspect(engine).get_indexes("users")}


def test_migrations_make_email_non_unique_and_keep_google_sub_unique(tmp_path):
    database_url = f"sqlite:///{tmp_path / 'migrations.db'}"
    _alembic(database_url, "upgrade", "head")

    engine = create_engine(database_url)
    try:
        assert _indexes(engine) == {"ix_users_google_sub": True, "ix_users_email": False}

        with engine.begin() as connection:
            connection.execute(text("INSERT INTO users (google_sub, email) VALUES ('g-1', 'same@example.com')"))
            connection.execute(text("INSERT INTO users (google_sub, email) VALUES ('g-2', 'same@example.com')"))
        with pytest.raises(IntegrityError):  # google_sub stays unique
            with engine.begin() as connection:
                connection.execute(text("INSERT INTO users (google_sub, email) VALUES ('g-1', 'other@example.com')"))
    finally:
        engine.dispose()


def test_migration_0002_downgrades_and_reupgrades_cleanly(tmp_path):
    database_url = f"sqlite:///{tmp_path / 'roundtrip.db'}"
    _alembic(database_url, "upgrade", "head")
    _alembic(database_url, "downgrade", "0001_initial")

    engine = create_engine(database_url)
    try:
        assert _indexes(engine)["ix_users_email"] is True
    finally:
        engine.dispose()

    _alembic(database_url, "upgrade", "head")
    engine = create_engine(database_url)
    try:
        assert _indexes(engine)["ix_users_email"] is False
    finally:
        engine.dispose()

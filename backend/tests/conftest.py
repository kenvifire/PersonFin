import os
import sys
from pathlib import Path

# Make the `app` package importable regardless of the directory pytest is
# invoked from (e.g. `pytest backend/tests/test_health.py` from the repo root).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Settings fields are required with no hardcoded defaults (see app/config.py),
# so tests provide their own throwaway values via the environment rather than
# depending on a real .env file.
os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")
os.environ.setdefault("JWT_SECRET", "test-jwt-secret")
os.environ.setdefault("GOOGLE_CLIENT_ID", "test-google-client-id")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "test-google-client-secret")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402
from sqlalchemy.pool import StaticPool  # noqa: E402

import app.models  # noqa: E402,F401 — registers all model tables on Base.metadata
from app.db import Base, get_db  # noqa: E402
from app.main import app  # noqa: E402

# A single in-memory SQLite engine, shared via StaticPool so every connection
# checked out during a test sees the same database.
test_engine = create_engine(
    "sqlite:///:memory:",
    connect_args={"check_same_thread": False},
    poolclass=StaticPool,
)
TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=test_engine)


@pytest.fixture()
def db_session():
    """A SQLAlchemy session backed by a fresh in-memory SQLite schema."""
    Base.metadata.create_all(bind=test_engine)
    session = TestingSessionLocal()
    try:
        yield session
    finally:
        session.close()
        Base.metadata.drop_all(bind=test_engine)


@pytest.fixture()
def client(db_session):
    """A FastAPI TestClient whose `get_db` dependency is overridden to use
    the same in-memory `db_session`, so assertions can inspect rows created
    through API calls directly."""

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    try:
        with TestClient(app) as test_client:
            yield test_client
    finally:
        app.dependency_overrides.clear()

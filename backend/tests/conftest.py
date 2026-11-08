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
os.environ.setdefault("JWT_SECRET", "test-jwt-secret-at-least-32-bytes-long")
os.environ.setdefault("GOOGLE_CLIENT_ID", "test-google-client-id")
os.environ.setdefault("GOOGLE_CLIENT_SECRET", "test-google-client-secret")
os.environ.setdefault("AZURE_OPENAI_ENDPOINT", "https://test.example/openai")
os.environ.setdefault("AZURE_OPENAI_API_KEY", "test-azure-openai-api-key")
os.environ.setdefault("AZURE_OPENAI_DEPLOYMENT", "test-deployment")
os.environ.setdefault("DEEPSEEK_API_KEY", "test-deepseek-key")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402
from sqlalchemy.pool import StaticPool  # noqa: E402

import app.models  # noqa: E402,F401 — registers all model tables on Base.metadata
from app.db import Base, get_db  # noqa: E402
from app.main import app  # noqa: E402
from app.schemas.extraction import ExtractionResult  # noqa: E402
from app.schemas.insights import InsightsNarrative  # noqa: E402
from app.services import image_storage  # noqa: E402
from app.services.fx import FXRateUnavailable, get_fx_provider  # noqa: E402
from app.services.insights import InsightGenerationFailed, get_insight_generator  # noqa: E402
from app.services.vision import ExtractionFailed, get_vision_extractor  # noqa: E402


class FakeFXRateProvider:
    """Fixed exchange rates for tests, so nothing ever hits the real FX
    API. Covers every pair among `SUPPORTED_CURRENCIES` (both directions,
    derived from a fixed USD value per unit of each currency); any other
    pair raises `FXRateUnavailable`, like the real provider would.
    Records each lookup in `calls`.
    """

    USD_PER_UNIT = {
        "USD": 1.0,
        "CAD": 0.72,
        "CNY": 0.14,
        "HKD": 0.128,
        "SGD": 0.74,
    }

    def __init__(self) -> None:
        self.calls: list[tuple[str, str]] = []

    def get_rate(self, base: str, quote: str) -> float:
        self.calls.append((base, quote))
        if base not in self.USD_PER_UNIT or quote not in self.USD_PER_UNIT:
            raise FXRateUnavailable(base, quote)
        return self.USD_PER_UNIT[base] / self.USD_PER_UNIT[quote]


class FailingFXRateProvider:
    """Simulates an FX outage: every lookup fails."""

    def get_rate(self, base: str, quote: str) -> float:
        raise FXRateUnavailable(base, quote)


class FakeVisionExtractor:
    """A `VisionExtractor` that returns a fixed result or raises
    `ExtractionFailed`, so tests never hit the real Azure OpenAI API.
    Tests pick one or the other per call via
    `app.dependency_overrides[vision.get_vision_extractor] = lambda: FakeVisionExtractor(...)`,
    the same per-test override style used for `fx.get_fx_provider`.
    """

    def __init__(self, result: ExtractionResult | None = None, error: str | None = None):
        self.result = result
        self.error = error

    def extract(self, image_bytes: bytes, mime_type: str) -> ExtractionResult:
        if self.result is not None:
            return self.result
        raise ExtractionFailed(self.error)


class FakeInsightGenerator:
    """An `InsightGenerator` that returns a fixed result or raises
    `InsightGenerationFailed`, so tests never hit the real DeepSeek API.
    Same shape as `FakeVisionExtractor`.
    """

    def __init__(self, result: InsightsNarrative | None = None, error: str | None = None):
        self.result = result
        self.error = error

    def generate(self, dashboard, drift):
        if self.result is not None:
            return self.result
        raise InsightGenerationFailed(self.error)


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
def upload_base_dir(tmp_path) -> str:
    """An isolated upload directory, unique per test, so uploads never
    write into the real repo tree. Overrides
    `image_storage.get_upload_base_dir` for the rest of the test — the
    `client` fixture depends on this fixture so that override is always
    in place for it, and any test can also request this fixture
    directly to inspect the filesystem (e.g. to confirm a file was
    actually deleted on discard)."""
    base_dir = str(tmp_path / "uploads")
    app.dependency_overrides[image_storage.get_upload_base_dir] = lambda: base_dir
    return base_dir


@pytest.fixture()
def client(db_session, upload_base_dir):
    """A FastAPI TestClient whose `get_db` dependency is overridden to use
    the same in-memory `db_session`, so assertions can inspect rows created
    through API calls directly."""

    def override_get_db():
        yield db_session

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_fx_provider] = lambda: FakeFXRateProvider()
    app.dependency_overrides[get_vision_extractor] = lambda: FakeVisionExtractor(result=ExtractionResult())
    app.dependency_overrides[get_insight_generator] = lambda: FakeInsightGenerator(
        result=InsightsNarrative(summary="Stub insight narrative.", action_items=[])
    )
    try:
        with TestClient(app) as test_client:
            yield test_client
    finally:
        app.dependency_overrides.clear()


@pytest.fixture()
def auth_header_for(client, monkeypatch):
    """Returns a function that logs a user in (creating them on first use)
    via the real `POST /auth/google` flow and returns an `Authorization`
    header dict carrying their session token.

    Each call fakes `verify_google_id_token` to return a `GoogleProfile`
    derived from the given email, so distinct emails become distinct users
    without needing real Google ID tokens.
    """
    from app.auth.google_oauth import GoogleProfile

    def _login(email: str) -> dict[str, str]:
        monkeypatch.setattr(
            "app.routers.auth.verify_google_id_token",
            lambda token: GoogleProfile(sub=f"sub-{email}", email=email),
        )
        response = client.post("/auth/google", json={"id_token": "fake"})
        assert response.status_code == 200
        token = response.json()["access_token"]
        return {"Authorization": f"Bearer {token}"}

    return _login


@pytest.fixture()
def use_fx_provider(client):
    """Returns a function that swaps the FX provider the app uses for the
    rest of the test (e.g. to a `FailingFXRateProvider`, or a specific
    `FakeFXRateProvider` instance whose `calls` the test inspects)."""

    def _use(provider):
        app.dependency_overrides[get_fx_provider] = lambda: provider
        return provider

    return _use

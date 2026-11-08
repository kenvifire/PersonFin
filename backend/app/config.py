from functools import lru_cache

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# The only Postgres driver pinned in requirements.txt is psycopg (v3).
# SQLAlchemy maps a bare `postgresql://` / `postgres://` URL to psycopg2,
# which isn't installed, so such URLs are rewritten to name psycopg.
_POSTGRES_SCHEMES = ("postgresql://", "postgres://")
_PSYCOPG_SCHEME = "postgresql+psycopg://"


def normalize_database_url(url: str) -> str:
    for scheme in _POSTGRES_SCHEMES:
        if url.startswith(scheme):
            return _PSYCOPG_SCHEME + url.removeprefix(scheme)
    return url


class Settings(BaseSettings):
    """Application settings, loaded from environment variables (and a local
    .env file, if present)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    jwt_secret: str
    google_client_id: str
    google_client_secret: str
    fx_api_key: str | None = None
    # Local disk only — not a secret, just a path. Screenshots never leave
    # the server except for the one vision-extraction API call.
    upload_dir: str = "./data/uploads"
    azure_openai_endpoint: str
    azure_openai_api_key: str
    azure_openai_deployment: str

    @field_validator("database_url")
    @classmethod
    def _use_psycopg_driver(cls, url: str) -> str:
        return normalize_database_url(url)


@lru_cache
def get_settings() -> Settings:
    return Settings()

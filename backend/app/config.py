from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings, loaded from environment variables (and a local
    .env file, if present)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str
    jwt_secret: str
    google_client_id: str
    google_client_secret: str
    fx_api_key: str | None = None


@lru_cache
def get_settings() -> Settings:
    return Settings()

import pytest

from app.config import normalize_database_url


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("postgresql://u:p@db:5432/personfin", "postgresql+psycopg://u:p@db:5432/personfin"),
        ("postgres://u:p@db/personfin", "postgresql+psycopg://u:p@db/personfin"),
        ("postgresql+psycopg://u:p@db/personfin", "postgresql+psycopg://u:p@db/personfin"),
        ("sqlite:///:memory:", "sqlite:///:memory:"),
    ],
)
def test_normalize_database_url_selects_psycopg_driver(url, expected):
    assert normalize_database_url(url) == expected


def test_postgres_url_builds_an_engine_with_the_pinned_driver():
    """A bare `postgresql://` URL would otherwise make SQLAlchemy import
    psycopg2, which isn't installed. Building an engine doesn't connect."""
    from sqlalchemy import create_engine

    engine = create_engine(normalize_database_url("postgresql://u:p@localhost/personfin"))
    assert engine.dialect.driver == "psycopg"

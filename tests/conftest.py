import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

os.environ["DATABASE_URL"] = "sqlite:///./test_omsg.db"
os.environ["SECRET_KEY"] = "test-secret-key-omsg-min-32-bytes"
os.environ["SMS_PROVIDER"] = "test"
os.environ["AUTH_TEST_CODE"] = "12345"

from app.main import app  # noqa: E402
from app.core.database import engine  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def cleanup_db():
    db_file = Path("test_omsg.db")
    if db_file.exists():
        db_file.unlink()
    yield
    engine.dispose()
    if db_file.exists():
        db_file.unlink()


@pytest.fixture()
def client():
    with TestClient(app) as test_client:
        yield test_client

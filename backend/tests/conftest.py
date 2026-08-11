from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def client(tmp_path: Path) -> Iterator[TestClient]:
    settings = Settings(
        app_env="test",
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'test.db'}",
        local_storage_path=tmp_path / "audio",
        public_base_url="http://testserver",
        jwt_secret="test-secret-with-more-than-thirty-two-characters",
        mock_external_services=True,
        raw_audio_wait_seconds=0,
    )
    app = create_app(settings)
    with TestClient(app) as test_client:
        yield test_client


def create_user(client: TestClient, phone: str, role: str, name: str) -> tuple[str, dict]:
    requested = client.post(
        "/v1/auth/otp/request",
        json={"phone": phone, "role": role, "name": name},
    )
    assert requested.status_code == 202, requested.text
    verified = client.post(
        "/v1/auth/otp/verify",
        json={"phone": phone, "code": requested.json()["devCode"]},
    )
    assert verified.status_code == 200, verified.text
    payload = verified.json()
    return payload["accessToken"], payload["user"]


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}

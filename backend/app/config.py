from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    app_env: Literal["development", "test", "production"] = "development"
    api_prefix: str = "/v1"
    public_base_url: str = "http://localhost:8080"
    database_url: str = "sqlite+aiosqlite:///./.data/collog.db"
    jwt_secret: str = "development-only-change-me-at-least-32-chars"
    jwt_ttl_minutes: int = 60 * 24
    refresh_ttl_days: int = 30
    otp_ttl_seconds: int = 180
    dev_otp_code: str = "000000"
    mock_external_services: bool = True

    livekit_url: str = "ws://localhost:7880"
    livekit_internal_url: str | None = None
    livekit_api_key: str = ""
    livekit_api_secret: str = ""

    apns_voip_enabled: bool = False
    apns_environment: Literal["sandbox", "production"] = "sandbox"
    apns_team_id: str = ""
    apns_key_id: str = ""
    apns_bundle_id: str = ""
    apns_private_key_path: Path | None = None
    incoming_call_ttl_seconds: int = 45

    deepgram_api_key: str = ""
    deepgram_model: str = "nova-3"
    deepgram_language: str = "ko"
    deepgram_base_url: str = "https://api.deepgram.com"

    gemini_api_key: str = ""
    gemini_model: str = "gemini-3.6-flash"
    gemini_base_url: str = "https://generativelanguage.googleapis.com"

    storage_backend: Literal["local", "s3"] = "local"
    local_storage_path: Path = Path(".data/audio")
    upload_url_ttl_seconds: int = 900
    s3_endpoint_url: str | None = None
    s3_public_endpoint_url: str | None = None
    s3_region: str = "ap-northeast-2"
    s3_bucket: str = ""
    s3_access_key_id: str = ""
    s3_secret_access_key: str = ""
    s3_force_path_style: bool = True

    consent_document_version: str = "2026-08-01.v3"
    parent_min_speech_seconds: int = 20
    raw_audio_wait_seconds: int = 30
    baseline_required_samples: int = 3
    baseline_window_weeks: int = 4
    robust_z_threshold: float = 1.5
    promoted_consecutive_weeks: int = 4

    cors_origins: list[str] = Field(default_factory=lambda: ["*"])

    @property
    def livekit_http_url(self) -> str:
        value = self.livekit_internal_url or self.livekit_url
        if value.startswith("wss://"):
            return "https://" + value.removeprefix("wss://")
        if value.startswith("ws://"):
            return "http://" + value.removeprefix("ws://")
        return value

    def ensure_local_directories(self) -> None:
        if self.database_url.startswith("sqlite"):
            database_path = self.database_url.rsplit("///", 1)[-1]
            if database_path != ":memory:":
                Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        if self.storage_backend == "local":
            self.local_storage_path.mkdir(parents=True, exist_ok=True)


@lru_cache
def get_settings() -> Settings:
    return Settings()

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

    # 기동 시 모델과 DB 스키마가 어긋나면 개발 DB를 재생성한다. 배포 서버는 false로 두어
    # guard가 스키마를 수정하지 못하게 한다. 그 환경의 스키마는 Alembic이 소유한다.
    # app_env로 분기하지 않는다. app_env="production"은 dev OTP를 막아 로그인을 불가능하게
    # 만들므로, 배포 서버도 development로 뜬다.
    schema_auto_reset: bool = True

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

    # Track Egress worker가 없는 개발 환경에서 기기의 분석용 PCM만으로 파이프라인을 돌린다.
    # 부모/자녀 트랙 분리 전사가 없으므로 운영에서는 반드시 false로 둔다.
    allow_raw_only_analysis: bool = False

    deepgram_api_key: str = ""
    deepgram_model: str = "nova-3"
    deepgram_language: str = "ko"
    deepgram_base_url: str = "https://api.deepgram.com"

    gemini_api_key: str = ""
    gemini_model: str = "gemini-3.6-flash"
    gemini_base_url: str = "https://generativelanguage.googleapis.com"
    gemini_max_output_tokens: int = 2048

    question_tts_provider: Literal["ios_local", "elevenlabs"] = "ios_local"
    elevenlabs_api_key: str = ""
    elevenlabs_voice_id: str = ""
    elevenlabs_model: str = "eleven_flash_v2_5"
    elevenlabs_output_format: str = "mp3_44100_128"
    elevenlabs_base_url: str = "https://api.elevenlabs.io"

    storage_backend: Literal["local", "s3"] = "local"
    local_storage_path: Path = Path(".data/audio")
    upload_url_ttl_seconds: int = 900
    tts_url_ttl_seconds: int = 3_600
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
    baseline_required_samples: int = 4
    baseline_window_weeks: int = 4
    robust_z_threshold: float = 1.5
    promoted_consecutive_weeks: int = 4
    acoustic_analyzer_version: str = "collog-acoustic-v3"
    cough_score_threshold: float = 0.65

    # 아래 값은 실측으로 보정되지 않은 잠정 상수다. 코드에 숨어 있으면 틀렸다는 사실조차
    # 드러나지 않으므로 설정으로 노출한다. 값을 바꿀 때에는 저장된 값과 구분되도록
    # acoustic_analyzer_version도 함께 올린다.
    quality_min_duration_sec: float = 5.0
    quality_max_clipping_ratio: float = 0.01
    quality_active_percentile: float = 90.0
    quality_min_active_dbfs: float = -55.0
    pause_min_gap_ms: int = 300
    pause_max_gap_ms: int = 2_000

    cors_origins: list[str] = Field(default_factory=lambda: ["*"])
    team_portal_enabled: bool = True
    team_portal_repository_url: str = "https://github.com/Frekion2002/14th-hackathon"

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

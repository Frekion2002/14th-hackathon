from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import httpx
import jwt

from app.config import Settings


class PushNotificationError(RuntimeError):
    pass


class UnregisteredVoipToken(PushNotificationError):
    pass


@dataclass(frozen=True, slots=True)
class IncomingCallPush:
    call_id: str
    caller_id: str
    caller_name: str
    expires_at: datetime

    def payload(self) -> dict:
        # The push only contains CallKit signaling metadata. LiveKit credentials and
        # health information are returned later by the authenticated accept endpoint.
        return {
            "aps": {"content-available": 1},
            "call": {
                "callId": self.call_id,
                "callUUID": self.call_id,
                "callerId": self.caller_id,
                "callerName": self.caller_name,
                "expiresAt": self.expires_at.astimezone(UTC).isoformat(),
            },
        }


class VoipPushGateway:
    async def send_incoming_call(self, token: str, push: IncomingCallPush) -> None:
        raise NotImplementedError

    async def close(self) -> None:
        return None


class DisabledVoipPushGateway(VoipPushGateway):
    async def send_incoming_call(self, token: str, push: IncomingCallPush) -> None:
        del token, push


class MockVoipPushGateway(VoipPushGateway):
    def __init__(self) -> None:
        self.sent: list[tuple[str, IncomingCallPush]] = []

    async def send_incoming_call(self, token: str, push: IncomingCallPush) -> None:
        self.sent.append((token, push))


class ApnsVoipPushGateway(VoipPushGateway):
    def __init__(
        self,
        settings: Settings,
        *,
        client: httpx.AsyncClient | None = None,
        private_key: str | None = None,
    ) -> None:
        missing = [
            name
            for name, value in (
                ("APNS_TEAM_ID", settings.apns_team_id),
                ("APNS_KEY_ID", settings.apns_key_id),
                ("APNS_BUNDLE_ID", settings.apns_bundle_id),
            )
            if not value
        ]
        if missing:
            raise PushNotificationError(f"APNs 설정이 누락되었습니다: {', '.join(missing)}")
        if private_key is None:
            if settings.apns_private_key_path is None:
                raise PushNotificationError("APNS_PRIVATE_KEY_PATH가 필요합니다")
            try:
                private_key = Path(settings.apns_private_key_path).read_text(encoding="utf-8")
            except OSError as exc:
                raise PushNotificationError("APNs .p8 키 파일을 읽을 수 없습니다") from exc

        self.settings = settings
        self.private_key = private_key
        self.client = client or httpx.AsyncClient(http2=True, timeout=10.0)
        self._provider_token: str | None = None
        self._provider_token_issued_at = 0

    @property
    def endpoint(self) -> str:
        if self.settings.apns_environment == "production":
            return "https://api.push.apple.com"
        return "https://api.sandbox.push.apple.com"

    def provider_token(self) -> str:
        now = int(datetime.now(UTC).timestamp())
        # Apple rejects provider tokens older than one hour. Refresh early so an
        # in-flight request never crosses that boundary.
        if self._provider_token is None or now - self._provider_token_issued_at >= 50 * 60:
            encoded = jwt.encode(
                {"iss": self.settings.apns_team_id, "iat": now},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.settings.apns_key_id},
            )
            self._provider_token = encoded
            self._provider_token_issued_at = now
        return self._provider_token

    def request_headers(self) -> dict[str, str]:
        return {
            "authorization": f"bearer {self.provider_token()}",
            "apns-topic": f"{self.settings.apns_bundle_id}.voip",
            "apns-push-type": "voip",
            "apns-priority": "10",
            "apns-expiration": "0",
        }

    def device_url(self, device_token: str) -> str:
        return f"{self.endpoint}/3/device/{device_token}"

    @staticmethod
    def normalize_device_token(token: str) -> str:
        normalized = re.sub(r"[\s<>]", "", token)
        if len(normalized) < 32 or not re.fullmatch(r"[0-9a-fA-F]+", normalized):
            raise PushNotificationError("iOS VoIP 토큰 형식이 올바르지 않습니다")
        return normalized.lower()

    async def send_incoming_call(self, token: str, push: IncomingCallPush) -> None:
        device_token = self.normalize_device_token(token)
        try:
            response = await self.client.post(
                self.device_url(device_token),
                headers=self.request_headers(),
                json=push.payload(),
            )
        except httpx.HTTPError as exc:
            raise PushNotificationError(f"APNs 연결 실패: {exc}") from exc

        if response.status_code == 200:
            return
        try:
            reason = response.json().get("reason", "UnknownAPNSError")
        except ValueError:
            reason = "UnknownAPNSError"
        if response.status_code == 410 or reason in {"BadDeviceToken", "Unregistered"}:
            raise UnregisteredVoipToken(reason)
        raise PushNotificationError(f"APNs 발송 실패 ({response.status_code}): {reason}")

    async def close(self) -> None:
        await self.client.aclose()


def create_voip_push_gateway(settings: Settings) -> VoipPushGateway:
    if settings.mock_external_services:
        return MockVoipPushGateway()
    if not settings.apns_voip_enabled:
        return DisabledVoipPushGateway()
    return ApnsVoipPushGateway(settings)

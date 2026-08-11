from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from typing import Annotated

import jwt
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.database import get_session
from app.models import User, UserRole

bearer = HTTPBearer(auto_error=False)


def otp_hash(phone: str, code: str, secret: str) -> str:
    return hashlib.sha256(f"{phone}:{code}:{secret}".encode()).hexdigest()


def issue_token(user: User, settings: Settings, *, refresh: bool = False) -> str:
    now = datetime.now(UTC)
    ttl = (
        timedelta(days=settings.refresh_ttl_days)
        if refresh
        else timedelta(minutes=settings.jwt_ttl_minutes)
    )
    return jwt.encode(
        {
            "sub": user.id,
            "role": user.role,
            "type": "refresh" if refresh else "access",
            "iat": now,
            "exp": now + ttl,
        },
        settings.jwt_secret,
        algorithm="HS256",
    )


async def current_user(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    session: Annotated[AsyncSession, Depends(get_session)],
) -> User:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "인증이 필요합니다")
    settings: Settings = request.app.state.container.settings
    try:
        payload = jwt.decode(credentials.credentials, settings.jwt_secret, algorithms=["HS256"])
        if payload.get("type") != "access":
            raise ValueError("not an access token")
    except (jwt.PyJWTError, ValueError) as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "유효하지 않은 인증 정보입니다") from exc
    user = await session.get(User, payload.get("sub"))
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "사용자를 찾을 수 없습니다")
    return user


CurrentUser = Annotated[User, Depends(current_user)]
SessionDep = Annotated[AsyncSession, Depends(get_session)]


def require_role(user: User, role: UserRole) -> None:
    if user.role != role.value:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "이 계정으로 수행할 수 없는 작업입니다")

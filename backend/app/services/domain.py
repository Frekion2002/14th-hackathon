from __future__ import annotations

from datetime import UTC, datetime

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    ConsentDecision,
    ConsentRecord,
    Family,
    FamilyMember,
    Invitation,
    User,
)


async def family_for_child(session: AsyncSession, child_id: str) -> Family | None:
    return await session.scalar(select(Family).where(Family.created_by == child_id))


async def latest_consent(session: AsyncSession, parent_id: str) -> ConsentRecord | None:
    return await session.scalar(
        select(ConsentRecord)
        .where(ConsentRecord.user_id == parent_id)
        .order_by(ConsentRecord.agreed_at.desc())
        .limit(1)
    )


async def has_consent(session: AsyncSession, parent_id: str) -> bool:
    record = await latest_consent(session, parent_id)
    return record is not None and record.decision == ConsentDecision.GRANTED.value


async def latest_invitation(session: AsyncSession, member_id: str) -> Invitation | None:
    return await session.scalar(
        select(Invitation)
        .where(Invitation.member_id == member_id)
        .order_by(Invitation.created_at.desc())
        .limit(1)
    )


async def derived_member_status(
    session: AsyncSession, member: FamilyMember, invitation: Invitation | None = None
) -> str:
    if member.user_id:
        consent = await latest_consent(session, member.user_id)
        if consent:
            return "CONSENT_GRANTED" if consent.decision == "GRANTED" else "CONSENT_DENIED"
    invitation = invitation or await latest_invitation(session, member.id)
    now = datetime.now(UTC)
    if invitation and invitation.expires_at.replace(tzinfo=UTC) <= now:
        return "INVITE_EXPIRED"
    return "AWAITING_CONSENT"


async def ensure_child_can_access_parent(
    session: AsyncSession, child: User, parent_id: str
) -> FamilyMember:
    family = await family_for_child(session, child.id)
    if family is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "가족 접근 권한이 없습니다")
    member = await session.scalar(
        select(FamilyMember).where(
            FamilyMember.family_id == family.id,
            FamilyMember.user_id == parent_id,
        )
    )
    if member is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "가족 접근 권한이 없습니다")
    return member


async def ensure_report_access(session: AsyncSession, user: User, parent_id: str) -> None:
    if user.role == "PARENT" and user.id == parent_id:
        return
    if user.role == "CHILD":
        await ensure_child_can_access_parent(session, user, parent_id)
        return
    raise HTTPException(status.HTTP_403_FORBIDDEN, "열람 권한이 없는 항목입니다")

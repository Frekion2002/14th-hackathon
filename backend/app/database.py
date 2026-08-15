from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


class Database:
    def __init__(self, url: str) -> None:
        self.engine: AsyncEngine = create_async_engine(url, pool_pre_ping=True)
        self.sessions = async_sessionmaker(self.engine, expire_on_commit=False)

    async def ensure_schema(self, *, auto_reset: bool) -> None:
        # schema_guard가 Base를 import하므로 순환을 피해 호출 시점에 가져온다.
        from app.schema_guard import ensure_schema

        await ensure_schema(self.engine, auto_reset=auto_reset)

    async def close(self) -> None:
        await self.engine.dispose()


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    database: Database = request.app.state.container.database
    async with database.sessions() as session:
        yield session

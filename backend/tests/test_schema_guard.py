from __future__ import annotations

import os
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.schema_guard import SchemaVerdict, compare, ensure_schema


def _drop_every_table(connection: sa.Connection) -> None:
    """fixture 전용 정리.

    `schema_guard`의 내부 함수를 재사용하지 않는다. 검증 대상이 정리까지 맡으면 그 함수가
    틀렸을 때 테스트도 같이 틀려서 실패가 드러나지 않는다.
    """
    reflected = sa.MetaData()
    reflected.reflect(connection)
    reflected.drop_all(connection)


@pytest.fixture
async def engine(tmp_path: Path) -> AsyncIterator[AsyncEngine]:
    # 기본은 테스트마다 새로 만드는 SQLite다. GUARD_TEST_DATABASE_URL을 주면 같은 검사를
    # Postgres에서 돌린다. SQLite는 외래키를 강제하지 않아 reflect 기반 drop의 삭제 순서를
    # 검증하지 못하므로, 배포 대상 dialect에서 한 번은 확인해야 한다.
    default_url = f"sqlite+aiosqlite:///{tmp_path / 'guard.db'}"
    created = create_async_engine(os.environ.get("GUARD_TEST_DATABASE_URL") or default_url)
    async with created.begin() as connection:
        await connection.run_sync(_drop_every_table)
    try:
        yield created
    finally:
        await created.dispose()


async def table_names(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as connection:
        return set(await connection.run_sync(lambda c: sa.inspect(c).get_table_names()))


async def execute(engine: AsyncEngine, statement: str) -> None:
    async with engine.begin() as connection:
        await connection.execute(sa.text(statement))


async def user_ids(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as connection:
        result = await connection.execute(sa.text("SELECT id FROM users"))
        return {row[0] for row in result}


async def insert_user(engine: AsyncEngine, user_id: str) -> None:
    await execute(
        engine,
        "INSERT INTO users (id, role, name, phone, created_at) "
        f"VALUES ('{user_id}', 'PARENT', '테스트', '{user_id}', '2026-08-14 00:00:00')",
    )


def test_identical_shapes_match() -> None:
    shape = {"users": frozenset({"id", "name"})}

    report = compare(model=shape, actual=shape)

    assert report.verdict is SchemaVerdict.MATCHED


def test_empty_database_is_fresh() -> None:
    report = compare(model={"users": frozenset({"id"})}, actual={})

    assert report.verdict is SchemaVerdict.FRESH


def test_whole_table_missing_is_additive() -> None:
    report = compare(
        model={"users": frozenset({"id"}), "calls": frozenset({"id"})},
        actual={"users": frozenset({"id"})},
    )

    assert report.verdict is SchemaVerdict.ADDITIVE
    assert report.missing_tables == frozenset({"calls"})


def test_missing_column_in_existing_table_is_drifted() -> None:
    report = compare(
        model={"users": frozenset({"id", "role"})},
        actual={"users": frozenset({"id"})},
    )

    assert report.verdict is SchemaVerdict.DRIFTED
    assert report.drifted_tables == {"users": frozenset({"role"})}


def test_drift_wins_over_additive() -> None:
    report = compare(
        model={"users": frozenset({"id", "role"}), "calls": frozenset({"id"})},
        actual={"users": frozenset({"id"})},
    )

    assert report.verdict is SchemaVerdict.DRIFTED


def test_extra_tables_and_columns_in_database_are_ignored() -> None:
    report = compare(
        model={"users": frozenset({"id"})},
        actual={"users": frozenset({"id", "legacy_flag"}), "parent_profiles": frozenset({"id"})},
    )

    assert report.verdict is SchemaVerdict.MATCHED


async def test_empty_database_is_created_from_models(engine: AsyncEngine) -> None:
    report = await ensure_schema(engine, auto_reset=True)

    assert report.verdict is SchemaVerdict.FRESH
    assert {"users", "calls", "consent_records"} <= await table_names(engine)


async def test_unchanged_schema_preserves_data(engine: AsyncEngine) -> None:
    await ensure_schema(engine, auto_reset=True)
    await insert_user(engine, "keep-me")

    report = await ensure_schema(engine, auto_reset=True)

    assert report.verdict is SchemaVerdict.MATCHED
    assert await user_ids(engine) == {"keep-me"}


async def test_missing_table_is_recreated_without_touching_other_data(
    engine: AsyncEngine,
) -> None:
    await ensure_schema(engine, auto_reset=True)
    await insert_user(engine, "keep-me")
    await execute(engine, "DROP TABLE reports")

    report = await ensure_schema(engine, auto_reset=True)

    assert report.verdict is SchemaVerdict.ADDITIVE
    assert report.missing_tables == frozenset({"reports"})
    assert "reports" in await table_names(engine)
    assert await user_ids(engine) == {"keep-me"}


async def test_missing_column_resets_the_database(engine: AsyncEngine) -> None:
    await ensure_schema(engine, auto_reset=True)
    await insert_user(engine, "goodbye")
    await execute(engine, "ALTER TABLE users DROP COLUMN name")

    report = await ensure_schema(engine, auto_reset=True)

    assert report.verdict is SchemaVerdict.DRIFTED
    assert report.drifted_tables == {"users": frozenset({"name"})}
    assert await user_ids(engine) == set()


async def test_reset_removes_tables_the_models_no_longer_declare(engine: AsyncEngine) -> None:
    await ensure_schema(engine, auto_reset=True)
    await execute(engine, "CREATE TABLE legacy_parent_profiles (parent_id TEXT PRIMARY KEY)")
    await execute(engine, "ALTER TABLE users DROP COLUMN name")

    await ensure_schema(engine, auto_reset=True)

    assert "legacy_parent_profiles" not in await table_names(engine)


async def test_additive_change_is_refused_when_auto_reset_is_off(engine: AsyncEngine) -> None:
    await ensure_schema(engine, auto_reset=True)
    await insert_user(engine, "keep-me")
    await execute(engine, "DROP TABLE reports")

    with pytest.raises(RuntimeError):
        await ensure_schema(engine, auto_reset=False)

    assert "reports" not in await table_names(engine)
    assert await user_ids(engine) == {"keep-me"}


async def test_drift_is_refused_without_touching_the_database(engine: AsyncEngine) -> None:
    await ensure_schema(engine, auto_reset=True)
    await insert_user(engine, "keep-me")
    await execute(engine, "ALTER TABLE users DROP COLUMN name")

    with pytest.raises(RuntimeError):
        await ensure_schema(engine, auto_reset=False)

    assert await user_ids(engine) == {"keep-me"}


async def test_empty_database_is_refused_when_auto_reset_is_off(engine: AsyncEngine) -> None:
    """migration을 돌리지 않고 앱만 배포한 경우다.

    guard가 대신 만들어 주면 Alembic head와 실제 스키마가 어긋나므로 거부해야 한다.
    """
    with pytest.raises(RuntimeError, match="alembic upgrade head"):
        await ensure_schema(engine, auto_reset=False)

    assert await table_names(engine) == set()

from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.schema_guard import SchemaVerdict, compare, ensure_schema


@pytest.fixture
async def engine(tmp_path: Path) -> AsyncIterator[AsyncEngine]:
    created = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'guard.db'}")
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

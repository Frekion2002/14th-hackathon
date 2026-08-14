from __future__ import annotations

import logging
from dataclasses import dataclass, field
from enum import StrEnum

import sqlalchemy as sa
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import AsyncEngine

from app.database import Base

logger = logging.getLogger(__name__)

Shape = dict[str, frozenset[str]]


class SchemaVerdict(StrEnum):
    MATCHED = "MATCHED"
    FRESH = "FRESH"
    ADDITIVE = "ADDITIVE"
    DRIFTED = "DRIFTED"


@dataclass(frozen=True)
class SchemaReport:
    verdict: SchemaVerdict
    missing_tables: frozenset[str] = frozenset()
    drifted_tables: dict[str, frozenset[str]] = field(default_factory=dict)


def compare(*, model: Shape, actual: Shape) -> SchemaReport:
    """모델이 요구하는 테이블·컬럼이 실제 DB에 있는지만 본다.

    DB에만 있는 테이블·컬럼은 앱을 깨뜨리지 않으므로 무시한다. 컬럼 타입은 dialect마다
    다르게 reflect되어 오탐을 만들므로 비교하지 않는다.
    """
    if not actual:
        return SchemaReport(SchemaVerdict.FRESH, missing_tables=frozenset(model))

    missing_tables = frozenset(model) - frozenset(actual)
    drifted_tables = {
        name: columns - actual[name]
        for name, columns in model.items()
        if name in actual and columns - actual[name]
    }

    if drifted_tables:
        return SchemaReport(
            SchemaVerdict.DRIFTED,
            missing_tables=missing_tables,
            drifted_tables=drifted_tables,
        )
    if missing_tables:
        return SchemaReport(SchemaVerdict.ADDITIVE, missing_tables=missing_tables)
    return SchemaReport(SchemaVerdict.MATCHED)


def model_shape(metadata: sa.MetaData) -> Shape:
    return {
        table.name: frozenset(column.name for column in table.columns)
        for table in metadata.tables.values()
    }


def _reflect_shape(connection: Connection) -> Shape:
    inspector = sa.inspect(connection)
    return {
        name: frozenset(column["name"] for column in inspector.get_columns(name))
        for name in inspector.get_table_names()
    }


def _drop_everything(connection: Connection) -> None:
    """모델이 아는 테이블이 아니라 DB에 실제로 있는 테이블을 전부 지운다.

    `Base.metadata.drop_all`은 모델에서 제거된 테이블을 남겨두므로 스키마가 계속 어긋난다.
    """
    reflected = sa.MetaData()
    reflected.reflect(connection)
    reflected.drop_all(connection)


def _refusal_message(report: SchemaReport) -> str:
    lines = ["DB 스키마가 모델과 일치하지 않아 기동을 중단합니다."]
    if report.missing_tables:
        lines.append(f"  없는 테이블: {', '.join(sorted(report.missing_tables))}")
    for table, columns in sorted(report.drifted_tables.items()):
        lines.append(f"  {table}에 없는 컬럼: {', '.join(sorted(columns))}")
    lines.append("  migration을 적용하세요: alembic upgrade head")
    return "\n".join(lines)


async def ensure_schema(engine: AsyncEngine, *, auto_reset: bool) -> SchemaReport:
    """기동 시 모델과 DB 스키마를 맞춘다.

    `auto_reset`이 False인 배포 환경에서는 스키마를 절대 수정하지 않는다. 그 환경의 스키마는
    Alembic이 소유하며, guard가 손대면 head revision과 실제 스키마가 어긋난다.
    """
    from app import models  # noqa: F401  Base.metadata에 모델을 등록한다

    async with engine.connect() as connection:
        actual = await connection.run_sync(_reflect_shape)

    report = compare(model=model_shape(Base.metadata), actual=actual)
    if report.verdict is SchemaVerdict.MATCHED:
        return report

    if not auto_reset:
        raise RuntimeError(_refusal_message(report))

    if report.verdict is SchemaVerdict.DRIFTED:
        async with engine.begin() as connection:
            await connection.run_sync(_drop_everything)
            await connection.run_sync(Base.metadata.create_all)
        logger.warning(
            "스키마가 어긋나 개발 DB를 재생성했습니다.\n"
            "  변경된 테이블: %s\n"
            "  데모 데이터를 다시 채우려면: uv run python scripts/seed_demo_family.py",
            ", ".join(sorted(report.drifted_tables)) or "-",
        )
        return report

    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    if report.verdict is SchemaVerdict.ADDITIVE:
        logger.info("새 테이블을 생성했습니다: %s", ", ".join(sorted(report.missing_tables)))
    return report

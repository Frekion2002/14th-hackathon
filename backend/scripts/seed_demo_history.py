from __future__ import annotations

import argparse
import asyncio
import json
from dataclasses import asdict

from app.config import Settings
from app.database import Database
from app.services.demo_seed import replace_demo_history


async def seed(parent_id: str, child_id: str) -> int:
    settings = Settings()
    database = Database(settings.database_url)
    try:
        async with database.sessions() as session:
            result = await replace_demo_history(
                session,
                parent_id=parent_id,
                child_id=child_id,
                settings=settings,
            )
    finally:
        await database.close()

    payload = asdict(result)
    print(json.dumps(payload, ensure_ascii=False, indent=2, default=str))
    print("주의: 위 통화·건강 대화·음향값은 모두 시연용 더미 데이터입니다.")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="시연 가족에 8주 더미 통화와 발화 속도 기준선·주간 리포트를 만든다"
    )
    parser.add_argument("--parent-id", required=True)
    parser.add_argument("--child-id", required=True)
    args = parser.parse_args()
    raise SystemExit(asyncio.run(seed(args.parent_id, args.child_id)))


if __name__ == "__main__":
    main()

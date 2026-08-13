from __future__ import annotations

import argparse
import asyncio
import json

import httpx

# 앱에는 아직 초대·동의·질환 프로필 화면이 없다. 실기기 통화를 시험하려면 자녀 계정에
# 연결된 부모 계정이 필요하므로, 개발 OTP로 두 계정을 만들고 초대→수락→동의→프로필까지
# 한 번에 진행한다. 개발 환경 전용이며 실제 건강정보를 넣지 않는다.


class SeedError(RuntimeError):
    pass


async def post(
    client: httpx.AsyncClient, path: str, body: dict | None = None, token: str | None = None
) -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    response = await client.post(path, json=body, headers=headers)
    if response.status_code >= 300:
        raise SeedError(f"POST {path} → {response.status_code} {response.text}")
    return response.json() if response.content else {}


async def put(client: httpx.AsyncClient, path: str, body: dict, token: str) -> dict:
    response = await client.put(path, json=body, headers={"Authorization": f"Bearer {token}"})
    if response.status_code >= 300:
        raise SeedError(f"PUT {path} → {response.status_code} {response.text}")
    return response.json()


async def get(client: httpx.AsyncClient, path: str, token: str | None = None) -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    response = await client.get(path, headers=headers)
    if response.status_code >= 300:
        raise SeedError(f"GET {path} → {response.status_code} {response.text}")
    return response.json()


async def login(client: httpx.AsyncClient, phone: str, role: str, name: str, code: str) -> dict:
    await post(client, "/v1/auth/otp/request", {"phone": phone, "role": role, "name": name})
    return await post(client, "/v1/auth/otp/verify", {"phone": phone, "code": code})


async def seed(args: argparse.Namespace) -> int:
    async with httpx.AsyncClient(base_url=args.base_url, timeout=15.0) as client:
        child = await login(client, args.child_phone, "CHILD", args.child_name, args.otp)
        child_token = child["accessToken"]
        family_id = child["user"]["familyId"]
        if not family_id:
            raise SeedError("자녀 계정에 가족이 없습니다")

        parent = await login(client, args.parent_phone, "PARENT", args.parent_name, args.otp)
        parent_token = parent["accessToken"]
        parent_id = parent["user"]["id"]

        # 이미 연결된 부모라면 초대를 다시 만들지 않는다.
        members = await get(client, f"/v1/families/{family_id}/members", child_token)
        already = next(
            (m for m in members["members"] if m.get("userId") == parent_id),
            None,
        )
        if already is None:
            invitation = await post(
                client,
                f"/v1/families/{family_id}/invitations",
                {"name": args.parent_name, "relation": args.relation},
                child_token,
            )
            await post(
                client,
                "/v1/invitations/accept",
                {"code": invitation["code"]},
                parent_token,
            )

        # 동의 기록이 아직 없으면 서버가 404를 준다.
        try:
            consent = await get(client, "/v1/consents/me", parent_token)
        except SeedError:
            consent = {}
        if consent.get("decision") != "GRANT":
            document = await get(client, "/v1/consents/document")
            await post(
                client,
                "/v1/consents",
                {
                    "documentVersion": document["version"],
                    "decision": "GRANT",
                    "scrolledToEnd": True,
                    "agreedItems": document["requiredItems"],
                },
                parent_token,
            )

        await put(
            client,
            f"/v1/parents/{parent_id}/profile",
            {"conditions": args.conditions},
            child_token,
        )

        members = await get(client, f"/v1/families/{family_id}/members", child_token)
        questions = await get(
            client, f"/v1/parents/{parent_id}/daily-questions", child_token
        )

    print(
        json.dumps(
            {
                "childPhone": args.child_phone,
                "childUserId": child["user"]["id"],
                "familyId": family_id,
                "parentPhone": args.parent_phone,
                "parentUserId": parent_id,
                "members": members["members"],
                "todayQuestions": [q["text"] for q in questions.get("questions", [])],
                "otp": args.otp,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="개발 환경에 자녀-부모 가족을 만들고 동의·질환 프로필까지 채운다"
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--child-phone", default="01000000002")
    parser.add_argument("--child-name", default="자녀")
    parser.add_argument("--parent-phone", default="01000000010")
    parser.add_argument("--parent-name", default="어머니")
    parser.add_argument("--relation", choices=["MOTHER", "FATHER"], default="MOTHER")
    parser.add_argument("--otp", default="000000")
    parser.add_argument(
        "--conditions",
        nargs="+",
        default=["HYPERTENSION"],
        choices=["DIABETES", "HYPERTENSION", "DYSLIPIDEMIA", "ASTHMA", "OBESITY"],
    )
    args = parser.parse_args()
    try:
        raise SystemExit(asyncio.run(seed(args)))
    except SeedError as exc:
        print(f"seed 실패: {exc}")
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()

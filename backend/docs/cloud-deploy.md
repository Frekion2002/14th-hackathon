# 클라우드 인스턴스 배포와 사전 검증

마지막 갱신: 2026-08-15

대상은 2026-08-18 개시하는 가비아 클라우드(2 vCore / 4 GB / 공인 IP 1개)다. 그 전에 같은
사양의 AWS EC2에서 절차를 한 번 밟아 8/18에 처음 겪는 문제를 없앤다.

## 1. 이 검증으로 확인하는 것

| 항목 | 왜 |
|---|---|
| **LiveKit이 공인 IP 뒤에서 미디어를 연결하는가** | 가장 깨지기 쉬운 부분. 실패해도 통화는 연결된 것처럼 보이고 소리만 안 난다 |
| **4 GB에 전체 스택이 들어가는가** | `schema-management-design.md` 5-2절의 메모리 추정은 실측이 아니다 |
| 배포 절차 자체 | 8/18에 처음 밟지 않기 위해 |

## 2. LiveKit 설정 — 가장 중요

`deploy/livekit.yaml`은 `rtc.use_external_ip: false`다. 로컬 LAN에서는 맞지만 **클라우드에서는
틀리다.** 인스턴스는 자기 사설 IP만 보고 클라이언트는 공인 IP로 접속하므로, LiveKit이 ICE
후보로 사설 IP를 광고해 미디어가 연결되지 않는다.

증상이 고약하다. signaling(7880)은 정상이라 **통화는 연결되고 소리만 나지 않는다.**

클라우드에서는 `deploy/livekit-cloud.yaml`을 쓴다.

```bash
export LIVEKIT_CONFIG_FILE=livekit-cloud.yaml
```

자동 탐지가 실패하면 `livekit-cloud.yaml`에 `rtc.node_ip: <공인 IP>`를 직접 적는다.

## 3. 인스턴스

| | 값 | 비고 |
|---|---|---|
| 타입 | **t3.medium** (2 vCPU / 4 GB) | 가비아와 동일 사양이라야 메모리 검증에 의미가 있다 |
| 프리티어 t2/t3.micro | **불가** | 1 GB로는 스택이 올라가지 않는다 |
| 비용 | 약 $0.042/hr | 3시간 검증이면 13센트. 끝나면 terminate |
| 디스크 | 20 GB 이상 | Docker 이미지가 크다 |

t3는 버스터블이라 CPU 크레딧이 소진되면 성능이 떨어진다. 기능 검증에는 무방하지만 CPU
여유를 측정할 때는 왜곡이 있다.

## 4. 보안 그룹 인바운드

**소스를 본인 공인 IP로 제한한다.** 이 스택은 LiveKit 키, MinIO 키, `JWT_SECRET`이 전부
개발용 고정값이라 공개 인터넷에 열어 두면 누구나 쓸 수 있다. iPhone도 같은 WiFi를 쓰면 같은
공인 IP로 나가므로 제한해도 접속된다.

| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 22 | TCP | SSH |
| 8080 | TCP | backend API |
| 7880 | TCP | LiveKit signaling |
| 7881 | TCP | WebRTC TCP fallback |
| **7882** | **UDP** | **WebRTC 미디어. 콘솔 기본이 TCP라 빠뜨리기 쉽다** |
| 9000 | TCP | MinIO. iOS가 PCM 업로드와 TTS 다운로드에 직접 접속한다 |

9000을 빠뜨리면 통화는 되는데 **PCM 업로드가 실패해 분석이 돌지 않는다.**

## 5. 인스턴스 준비

Ubuntu 24.04 기준이다.

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git
sudo usermod -aG docker $USER && exec sudo su - $USER
git clone https://github.com/Collog-App/14th-hackathon.git
cd 14th-hackathon/backend
```

## 6. 환경변수

세 주소가 모두 인스턴스의 **공인 IP**여야 한다. iPhone이 직접 접속하는 주소들이다.

```bash
export EIP=<인스턴스 공인 IP>
cat > .env <<EOF
LIVEKIT_CONFIG_FILE=livekit-cloud.yaml
PUBLIC_BASE_URL=http://${EIP}:8080
LIVEKIT_URL=ws://${EIP}:7880
S3_PUBLIC_ENDPOINT_URL=http://${EIP}:9000
SCHEMA_AUTO_RESET=false
DEEPGRAM_API_KEY=...
GEMINI_API_KEY=...
EOF
```

`SCHEMA_AUTO_RESET=false`가 배포 기본값이다. 이 값이면 guard가 스키마를 수정하지 않고, 모델과
DB가 어긋나면 기동을 거부한다. Alembic 도입 전이라 **빈 DB에서는 `FRESH` 판정으로 기동이
거부된다.** 검증 단계에서는 첫 기동만 `SCHEMA_AUTO_RESET=true`로 올려 테이블을 만든 뒤
`false`로 되돌린다. 근거는 `schema-management-design.md` 3-3절에 있다.

## 7. 기동

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f backend
```

## 8. 확인 순서

문제를 좁히기 좋은 순서다. 앞이 실패하면 뒤는 볼 필요가 없다.

**8-1. 메모리 실측 — 이 검증의 목적 중 하나**

```bash
free -m
docker stats --no-stream
```

`schema-management-design.md` 5-2절의 추정은 합계 약 1.3 GB다. 실제와 크게 다르면 그 절을
정정한다.

**8-2. API 도달**

```bash
curl http://${EIP}:8080/v1/health
```

**8-3. LiveKit signaling**

```bash
curl -i http://${EIP}:7880
```

**8-4. ICE 후보에 공인 IP가 실리는가 — 2절의 핵심**

```bash
docker compose logs livekit | grep -i "external\|node_ip\|candidate"
```

사설 IP(`172.31.x.x`, `10.x.x.x`)만 보이면 `use_external_ip`가 동작하지 않은 것이다.
`rtc.node_ip`를 직접 지정한다.

**8-5. 두 iPhone 실제 통화**

`two-iphone-e2e.md` 절차를 그대로 따르되 LAN 주소 대신 공인 IP를 쓴다. **소리가 오가는지가
진짜 판정이다.** 연결만 되고 무음이면 2절 문제다.

## 9. iOS ATS

EC2 기본 호스트명(`ec2-*.compute.amazonaws.com`)으로는 Let's Encrypt 인증서를 받을 수 없다.
가비아의 공인 IP도 마찬가지다. 이 검증 단계에서는 `Info.plist`의 ATS 예외로 HTTP를 허용하고
넘어간다. 데모용 TLS 방식은 별도 결정 사항이며 `HANDOFF.md` 8절에 미결정으로 있다.

## 10. 정리

```bash
docker compose down -v
```

EC2 인스턴스는 검증이 끝나면 **terminate 한다.** 중지만 하면 EBS 요금이 계속 나온다.

## 11. 결과 기록

메모리 실측치와 LiveKit ICE 결과를 `HANDOFF.md` 6절에 남긴다. 8/18 가비아 배포는 이 문서의
같은 절차를 따르며, 다른 것은 공인 IP와 인스턴스 제공자뿐이다.

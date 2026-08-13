# 콜록(Collog)

멋사 14기 해커톤 프로젝트. 가족이 이미 하던 전화 한 통을 건강 변화 기록으로 바꾸는 가족
VoIP 앱이다.

현재 구현된 범위는 [`backend/`](backend/)에 있다. FastAPI API, self-hosted LiveKit 통화·녹음,
Deepgram Nova-3 한국어 STT, Gemini 부모 근거 구조화, 되묻기 탐지, 음향 4종 prototype,
calendar-week 기준선·리포트 파이프라인, iOS PushKit과 ElevenLabs 한국어 질문 TTS를 포함한다.

- 실행 및 배포: [`backend/README.md`](backend/README.md)
- 전체 인수인계 및 현재 상태: [`HANDOFF.md`](HANDOFF.md)
- Swift/iOS 통화 계약: [`backend/docs/ios-call-flow.md`](backend/docs/ios-call-flow.md)
- iPhone 2대 E2E 검증: [`backend/docs/two-iphone-e2e.md`](backend/docs/two-iphone-e2e.md)

팀원과 AI는 작업을 시작하기 전에 반드시 `HANDOFF.md`를 전체 확인하고, 코드 변경과 문서 갱신을
같은 커밋으로 push한다.

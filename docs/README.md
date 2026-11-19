# 문서 안내

## 문서 위치

| 문서 | 내용 |
|---|---|
| [README](../README.md) | 현재 구성, 새 클러스터 구축, 운영 접속. 버전·사양·주소 같은 현재 값은 여기에만 쓴다 |
| [AGENTS.md](../AGENTS.md) | 저장소 규칙, 컨벤션, 함께 바꿀 것, 안티패턴 |
| [runbooks/postgresql.md](runbooks/postgresql.md) | PostgreSQL 설치, 튜닝, 역할, 서비스 DB 추가, Tailscale, Datadog 호스트 Agent, 백업과 복원 |
| [runbooks/oke-upgrade.md](runbooks/oke-upgrade.md) | OKE 제어 플레인과 워커 업그레이드 |
| [backlog.md](backlog.md) | 남은 일 |
| [incidents/](incidents/) | 날짜별 장애·작업 기록 |

## 문서 종류와 템플릿

| 종류 | 위치 | 템플릿 | 쓰는 경우 |
|---|---|---|---|
| 런북 | `docs/runbooks/{주제}.md` | [runbook.md](templates/runbook.md) | 다시 수행할 운영 절차 |
| 기록 | `docs/incidents/YYYY-MM-DD-{주제}.md` | [record.md](templates/record.md) | 장애 대응, 업그레이드·이전처럼 한 번 수행한 작업 |
| 남은 일 | `docs/backlog.md` | 문서 안의 표 | 기록이나 작업 중에 생긴 후속 작업 |

## 작성 규칙

- 한국어 평서문으로 쓴다.
- 템플릿의 절 순서를 지킨다. 해당하지 않는 절은 지우되 요약, 조치, 검증은 남긴다.
- 현재 값은 README의 "현재 구성"과 PostgreSQL 런북의 "적용 구성"에만 쓰고 다른 문서는 링크한다.
- 기록에는 그날 확인한 사실만 쓴다. 이후 상태 변화는 backlog와 런북에 반영하고, 기록은 사실 오류가 있을 때만 고친다.
- 남은 일은 기록에 목록으로 쌓지 않고 backlog에 등록한다. 끝난 항목은 backlog에서 지운다.
- 비밀번호, 토큰, 개인 키 값은 쓰지 않는다. 저장 위치나 조회 명령만 쓴다.
- 실제로 수행해 보지 않은 절차는 "미검증"으로 표시한다.

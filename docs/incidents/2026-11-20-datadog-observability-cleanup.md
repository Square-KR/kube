# Datadog 대시보드·로그 파이프라인·모니터 정리

| 항목 | 내용 |
|---|---|
| 일시 | 2026-11-20 16:30 ~ 17:20 KST |
| 유형 | 작업 |
| 대상 | Datadog(`us5`) 대시보드·로그 파이프라인·모니터, ArgoCD HTTPRoute, Datadog Agent, ArgoCD 로그 레벨 |
| 상태 | 완료 |

## 요약

접근·DB·인프라 지표를 한 화면에서 보는 대시보드 `Square-KR Overview`를 만들고, Envoy 접근 로그에서 클라이언트 IP·국가·User-Agent를 뽑는 로그 파이프라인을 추가했다. 거짓 알림과 아무에게도 가지 않던 알림을 정리해 이메일 알림을 태그 하나로 통일했다. 조사 중 찾은 ArgoCD 스트림 504와 노이즈 로그는 저장소에서 고쳤다.

## 영향

없음. 서비스 트래픽이 지나지 않는 ArgoCD HTTPRoute, Datadog Agent, ArgoCD 컴포넌트만 바뀌었다.

## 타임라인

| 시각 (KST) | 내용 |
|---|---|
| 16:42 | 대시보드 `Square-KR Overview`(`gdn-pyx-uk7`) 생성 |
| 16:46 | 로그 파이프라인 `Envoy Gateway access log` 생성 |
| 16:51 | 디스크 forecast 모니터에서 `/dev/loop*` 제외 |
| 16:53 | 파이프라인에 User-Agent·URL 파서 추가 |
| 16:55 | 대시보드에 알림 중 모니터, 봇·404·DB 상위 쿼리 위젯 추가 |
| 17:07 | #13 머지. ArgoCD HTTPRoute 요청 타임아웃 해제 |
| 17:10 | 모니터 5개 삭제, 6개 수정, 2개 추가 |
| 17:14 | 디스크 70%·80% 임계값, ArgoCD repo-server 가용성 모니터 |

## 배경과 원인

- 대시보드가 없어 접근 IP, DB, 노드 상태를 각각 다른 화면에서 봐야 했다.
- Envoy 접근 로그는 JSON이라 Datadog 기본 Envoy 파이프라인이 해석하지 못했다. `x-forwarded-for`는 `<클라이언트 IP>,<OCI LB 사설 IP>` 형태다.
- 최근 72시간 `argocd.sqr.kr`의 UT(업스트림 타임아웃) 약 180건이 모두 약 15초에서 끊겼다. Envoy Gateway 기본 요청 타임아웃이 ArgoCD UI의 watch 스트림과 로그 follow를 끊었다. 같은 기간 `mllm.kr` 504 9건은 11-19 02:09 노드 CPU 포화 때, 503은 11-19 OKE 업그레이드 중 노드 교체 때 났다.
- 모니터 28개 중 다수가 태그도 `@` 대상도 없어 아무에게도 알리지 않았다. host 팩 모니터 7개는 `@your-team-handle` 같은 템플릿 값을 그대로 썼다. 최근 30일 알림 이벤트 1,000건 중 760건이 옛 워커의 CPU·System load 모니터가 반복해서 켜졌다 꺼진 것이었다. prod honami 가용성 모니터는 없었다.
- 11-19 노드 교체 뒤 삭제한 노드 `10.20.1.108`, `10.20.1.58`이 Agent 통신 중단·노드 NotReady 모니터에 Alert·Warn 그룹으로 남아 있었다.
- 하루 로그 약 57만 건 중 CoreDNS 쿼리 로그(22.5만), OKE `discovery-agent`(21.7만), ArgoCD application-controller·repo-server info(9.7만)가 약 95%였다.
- "평균 쿼리 실행 시간" 지표의 99% 이상이 Datadog Agent 계정(`square_datadog`, `postgres`)의 모니터링·EXPLAIN 쿼리였다.

## 조치

| 커밋 | 내용 |
|---|---|
| `42edcf8` | ArgoCD HTTPRoute `timeouts.request: 0s` |
| #14 | Agent `DD_CONTAINER_EXCLUDE_LOGS`(`coredns`, `discovery-agent`), ArgoCD controller·repo-server 로그 레벨 `warn`, OKE 런북에 노드 교체 후 모니터 그룹 Resolve 단계, 이 기록 |

저장소 밖에서 한 작업:

- 대시보드 `Square-KR Overview`: 맨 위 알림 중 모니터, 접근(Envoy 로그 기준 요청·5xx·p95·클라이언트 IP·국가·경로·봇·404), DB(연결·히트율·TPS·앱 계정 쿼리 시간·상위 쿼리), 인프라(노드·파드·CPU·메모리·디스크·컨테이너) 그룹, 기본 대시보드 링크 메모. 도메인 변수 `$domain`(`@requested_server_name`, 기본 `mllm.kr`).
- 로그 파이프라인 `Envoy Gateway access log`(`source:envoy kube_namespace:envoy-gateway-system`): `x-forwarded-for` 첫 IP → `network.client.ip`, GeoIP, User-Agent(`user-agent` → `http.useragent_details`), URL(`x-envoy-origin-path` → `http.url_details`), `response_code` → `http.status_code`, 5xx error·4xx warning 상태. 생성 이후 로그에만 적용된다.
- 모니터 삭제: Redis 메모리(Redis 없음), System load, Network 송수신 2개, Pods Restarting.
- 모니터 수정: host 팩 4개에서 템플릿 알림 대상 제거, CPU 15분 평균, 디스크 지연을 호스트·디바이스별로, Deployment·StatefulSet 레플리카 부족 임계값 2 → 1, 디스크 사용률 70% 경고·80% 심각(5분).
- 모니터 추가: honami 가용 Pod 없음, `mllm.kr` 5xx 10분 10건 초과, ArgoCD repo-server 가용 Pod 없음.
- 이메일은 태그 `notification:critical_email`이 붙은 모니터만 notification rule `squarek8s 중요 장애 이메일`로 보낸다. Agent 통신 중단 모니터만 message에 수신자를 직접 적는다.
- 17:10 조회에서 삭제한 노드의 모니터 그룹은 모두 OK였다.
- backlog "노드 CPU·디스크 경보"의 DiskPressure 조건은 기존 service check 모니터(5회 연속, 약 75초)로 충족한다.

## 검증

- 파이프라인 적용 후 로그에 `network.client.ip`, 국가(`KR`), User-Agent 분류(Googlebot → `Bot`), URL 경로(`/cafeteria?_rsc=…` → `/cafeteria`)가 들어왔다.
- 대시보드 메트릭 쿼리 20개와 로그 필터를 API로 실행해 값이 나오는 것을 확인했다.
- Envoy 접근 로그 수(24시간 2,509건)가 Envoy HTTPS 요청 지표(2,480건)와 거의 같아 로그 기준 위젯이 요청을 빠짐없이 센다.
- 클러스터의 ArgoCD HTTPRoute에 `timeouts.request: 0s`가 들어갔고 `Accepted`다.

## 결정 사항

- 이메일 알림 대상은 모니터 message가 아니라 태그 `notification:critical_email`로 정한다.
- 노이즈 로그는 인덱스 제외 필터 대신 Agent 수집 단계에서 막는다. MCP로는 인덱스를 수정할 수 없다.
- 대시보드와 모니터는 Datadog에서 직접 관리하고 이 기록에 남긴다.

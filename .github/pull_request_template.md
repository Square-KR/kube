<!--
제목은 커밋 규칙과 같은 `type: 영어 소문자 요약`으로 쓴다. squash merge 커밋 제목이 된다.
type: feat, fix, refactor, chore, docs, ci
해당하지 않는 절과 항목은 지운다.
본문은 존댓말로, 결론부터 짧은 문장으로 쓴다.
-->

## 📌 배경

<!-- 왜 바꾸는지 쓴다. 로그·지표·장애 기록이 근거면 수치와 링크를 함께 쓴다. -->

## ✅ 변경 사항

<!-- 파일별로 무엇을 왜 바꿨는지 쓴다. -->

- `경로`:

## 🚀 적용 방식

<!-- GitOps 밖에서 따로 적용해야 하는 변경이 있는지 표시한다. -->

- [ ] ArgoCD 자동 sync만으로 반영된다
- [ ] Terraform apply: 머지 전 완료 / 머지 후 필요
- [ ] ArgoCD 설정 `helmfile apply` 필요
- [ ] CRD 수동 적용 필요 (Envoy Gateway 등)
- [ ] 호스트·OCI 콘솔·CLI 수동 작업 필요
- [ ] 문서만 바뀐다

## 🔍 확인

<!-- 실행한 것만 체크하고, plan·diff 결과는 요약을 남긴다. -->

- [ ] `scripts/validate-manifests.sh`
- [ ] 클러스터 server-side dry-run
- [ ] `terraform fmt`, `terraform plan`:
- [ ] `helmfile diff`:
- [ ] `shellcheck -S warning`

## ⚠️ 위험과 롤백

<!--
AGENTS.md "불변 조건"에 닿는지, 재시작되는 컴포넌트와 예상 중단 시간, 되돌리는 방법을 쓴다.
Terraform은 replace·destroy가 있으면 대상과 이유를 쓴다.
-->

## 📋 머지 후 할 일

<!-- 머지 후 직접 적용할 것과 확인할 로그·지표를 쓴다. 없으면 지운다. -->

## 📝 문서

- [ ] README "현재 구성"
- [ ] AGENTS.md "함께 바꿀 것", "불변 조건"
- [ ] 런북
- [ ] 기록 `docs/incidents/YYYY-MM-DD-{주제}.md`
- [ ] backlog 추가·삭제

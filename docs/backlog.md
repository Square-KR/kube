# 남은 일

새 항목은 우선순위에 맞는 위치에 추가한다. 끝난 항목은 지우고, 완료 내용은 커밋이나 기록에 남긴다.

| 우선순위 | 항목 | 내용 | 출처 |
|---|---|---|---|
| 높음 | 시스템 파드 resource requests | `kube-system`을 제외한 시스템 컨테이너 대부분이 requests 없이 BestEffort로 실행된다. 스케줄러가 노드 여유를 판단하지 못해 한 노드에 몰릴 수 있다. 11-19 kubelet 무응답의 배경이다 | [정리 기록](incidents/2026-11-19-repo-and-cluster-cleanup.md) |
| 높음 | 노드 CPU·디스크 경보 | Datadog 모니터: 루트 파일시스템 70% 15분 경고·80% 5분 심각, `DiskPressure=True` 1분, ArgoCD repo-server Ready 0. Datadog UI에서 직접 구성한다 | [DiskPressure 기록](incidents/2026-09-10-disk-pressure.md) |
| 중간 | PostgreSQL 볼륨 복원 시험 | 첫 정기 백업은 2026-11-19 03:00 KST에 생성됐다. [런북](runbooks/postgresql.md#백업과-복원)의 볼륨 복원 절차는 한 번도 수행하지 않았다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 중간 | DB 호스트 Datadog 태그 | 호스트 Agent의 `env:dev` 태그가 prod `honami` DB 지표에도 붙는다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 중간 | OCI 보안 목록 잔여 규칙 | Cloud Controller가 예전에 추가한 NodePort 규칙(worker ingress 3건, public egress 3건)이 남아 있다. `terraform/main.tf`의 `ignore_changes`를 빼고 plan으로 삭제 범위를 확인한 뒤 정리한다 | [정리 기록](incidents/2026-11-19-repo-and-cluster-cleanup.md) |
| 낮음 | SELinux 모드 불일치 | 워커의 `/etc/selinux/config`는 `enforcing`인데 런타임은 `Permissive`다. Enforcing 전환은 hostPath를 쓰는 모든 워크로드를 검증한 뒤에 한다 | [DiskPressure 기록](incidents/2026-09-10-disk-pressure.md) |
| 낮음 | ArgoCD admin 계정 | `argocd-initial-admin-secret`이 남아 있고 admin 계정을 그대로 쓴다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | ClusterSecretStore 범위 | `aws-ssm`을 모든 네임스페이스가 쓸 수 있다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | Gateway route 허용 범위 | 모든 listener가 `allowedRoutes.namespaces.from: All`이다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | GitHub Actions 고정 | action을 태그로 참조한다. 커밋 SHA로 고정한다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | OCI 네트워크 구성 | 11-19 점검에서 권장 사항과 다르다고 표시한 OCI 네트워크 구성을 항목별로 다시 검토한다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | AppProject 분리 | 모든 Application이 `default` AppProject를 쓴다 | [2026-11-19 기록](incidents/2026-11-19-gitops-drift-and-node-cpu.md) |
| 낮음 | ApplicationSet 통합 검토 | 서비스별 ApplicationSet 3개가 거의 같다. 템플릿의 `resources-finalizer` 때문에 교체 중 prod 리소스가 삭제될 수 있으므로 finalizer 제거 절차부터 설계한다 | [정리 기록](incidents/2026-11-19-repo-and-cluster-cleanup.md) |

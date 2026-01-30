# 노드 세팅

```yaml
tls-san:
  - (마스터 노드 IP)
flannel-backend: none
disable-network-policy: true
disable:
  - traefik
  - servicelb
# 기본 설치 과정 이후, 설정 파일 수정
```

```sh
sudo systemctl disable --now firewalld
# OS 레벨 방화벽 미사용
```

## 개발 환경

기본적인 kubectl + kubectx 세팅 이후, `sh bootstrap.sh` 실행

```sh
helm plugin install https://github.com/databus23/helm-diff
# helm 파일 diff 비교 플러그인 설치
```

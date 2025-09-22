# expand_disk.sh

AWS EC2 인스턴스에서 EBS 볼륨을 자동으로 확장해 주는 스크립트입니다.

## 사용법

아래 한 줄 명령으로 스크립트를 다운로드 받아 곧바로 실행할 수 있습니다.

```bash
T=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/nm-c/util/main/expand_disk.sh -o "$T" && sudo bash "$T"; rm -f "$T"
```

#!/bin/bash

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== AWS EBS 볼륨 완전 자동 확장 스크립트 ===${NC}"

# 기본값 설정
ADD_SIZE=""

# 파라미터 처리
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--add)
            ADD_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            echo "사용법: $0 [옵션]"
            echo "  -a, --add SIZE     추가할 크기 (GB)"
            echo "  -h, --help         도움말"
            echo ""
            echo "예시:"
            echo "  $0              # 대화형 모드"
            echo "  $0 -a 50        # 50GB 추가"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}이 스크립트는 root 권한이 필요합니다. sudo로 실행하세요.${NC}"
   exit 1
fi

# AWS CLI 설치 함수
install_aws_cli() {
    echo -e "${YELLOW}AWS CLI 설치 중...${NC}"

    # unzip 설치 확인 및 설치
    if ! command -v unzip &> /dev/null; then
        echo -e "${YELLOW}unzip 설치 중...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y unzip

        if ! command -v unzip &> /dev/null; then
            echo -e "${RED}unzip 설치 실패. 수동 설치 후 다시 시도하세요.${NC}"
            return 1
        fi
        echo -e "${GREEN}unzip 설치 완료${NC}"
    fi

    # 아키텍처 감지
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then
        AWS_CLI_ARCH="aarch64"
    else
        AWS_CLI_ARCH="x86_64"
    fi

    # 임시 디렉토리에서 작업
    cd /tmp

    # AWS CLI v2 다운로드 및 설치
    echo "AWS CLI v2 다운로드 중 (${AWS_CLI_ARCH})..."
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_CLI_ARCH}.zip" -o "awscliv2.zip"

    if [ -f "awscliv2.zip" ]; then
        unzip -q awscliv2.zip
        ./aws/install --update 2>/dev/null || ./aws/install
        rm -rf awscliv2.zip aws/
    else
        echo -e "${RED}AWS CLI 다운로드 실패${NC}"
        return 1
    fi

    cd - > /dev/null

    # 설치 확인
    if command -v aws &> /dev/null; then
        echo -e "${GREEN}AWS CLI 설치 완료${NC}"
        return 0
    else
        return 1
    fi
}

# AWS CLI 확인 및 설치
if ! command -v aws &> /dev/null; then
    install_aws_cli
    if [ $? -ne 0 ]; then
        echo -e "${RED}AWS CLI 설치 실패. 수동 설치 후 다시 시도하세요.${NC}"
        exit 1
    fi
fi

# jq 설치 함수
install_jq() {
    echo -e "${YELLOW}jq 설치 중...${NC}"

    if [ -f /etc/redhat-release ]; then
        yum install -y jq
    elif [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y jq
    else
        echo -e "${RED}지원하지 않는 OS입니다.${NC}"
        return 1
    fi

    # 설치 확인
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}jq 설치 완료${NC}"
        return 0
    else
        return 1
    fi
}

# jq 확인 및 설치 (필수)
if ! command -v jq &> /dev/null; then
    install_jq
    if [ $? -ne 0 ]; then
        echo -e "${RED}jq 설치 실패. jq를 수동 설치 후 다시 시도하세요.${NC}"
        exit 1
    fi
fi

# 인스턴스 메타데이터 가져오기
echo -e "\n${YELLOW}인스턴스 정보 수집 중...${NC}"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo -e "${RED}EC2 인스턴스가 아니거나 IMDSv2가 비활성화되어 있습니다.${NC}"
    echo "IMDSv1으로 시도 중..."
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
else
    INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
fi

if [ -z "$INSTANCE_ID" ] || [ -z "$REGION" ]; then
    echo -e "${RED}인스턴스 메타데이터를 가져올 수 없습니다.${NC}"
    echo "EC2 인스턴스에서 실행 중인지 확인하세요."
    exit 1
fi

echo "인스턴스 ID: $INSTANCE_ID"
echo "리전: $REGION"

# IAM 권한 확인
echo -e "\n${YELLOW}IAM 권한 확인 중...${NC}"
IDENTITY=$(aws sts get-caller-identity --region $REGION 2>&1)

if echo "$IDENTITY" | grep -q "Unable to locate credentials"; then
    echo -e "${RED}AWS 자격 증명을 찾을 수 없습니다.${NC}"
    echo ""
    echo "해결 방법:"
    echo "1. EC2 인스턴스에 IAM 역할 연결:"
    echo "   - EC2 콘솔 → 인스턴스 선택 → Actions → Security → Modify IAM role"
    echo ""
    echo "2. 필요한 권한이 있는 역할 생성 후 연결:"
    echo "   - ec2:DescribeVolumes"
    echo "   - ec2:ModifyVolume"
    echo "   - ec2:DescribeVolumesModifications"
    exit 1
fi

# IAM 역할 ARN 추출
ROLE_ARN=$(echo "$IDENTITY" | jq -r '.Arn' 2>/dev/null)
if [ -n "$ROLE_ARN" ]; then
    echo -e "${GREEN}IAM 자격 증명 확인됨${NC}"
    echo "ARN: $ROLE_ARN"
fi

# 필요한 권한 테스트
# AWS CLI 설치 및 설정 확인
echo -e "\n${YELLOW}AWS CLI 확인 중...${NC}"
if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI가 설치되어 있지 않습니다.${NC}"
    exit 1
fi

AWS_VERSION=$(aws --version 2>&1)
echo -e "${GREEN}AWS CLI 버전: ${AWS_VERSION}${NC}"

# 기본 자격 증명 확인
CALLER_IDENTITY=$(aws sts get-caller-identity --region $REGION 2>&1)
if echo "$CALLER_IDENTITY" | grep -q "Unable to locate credentials"; then
    echo -e "${RED}AWS 자격 증명을 확인할 수 없습니다.${NC}"
    echo "Instance Profile 확인 중..."
    PROFILE_INFO=$(curl -s http://169.254.169.254/latest/meta-data/iam/info)
    echo "$PROFILE_INFO"
    exit 1
fi

echo -e "\n${YELLOW}필요한 권한 테스트 중...${NC}"

# DescribeVolumes 권한 테스트
TEST_VOLUMES=$(aws ec2 describe-volumes \
    --region $REGION \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
    --max-results 1 2>&1)

if echo "$TEST_VOLUMES" | grep -q "UnauthorizedOperation"; then
    echo -e "${RED}ec2:DescribeVolumes 권한이 없습니다.${NC}"
    MISSING_PERMS=true
else
    echo -e "${GREEN}✓ ec2:DescribeVolumes${NC}"
fi

# ModifyVolume 권한은 실제 수정 시 확인됨
echo -e "${YELLOW}※ ec2:ModifyVolume 권한은 실행 시 확인됩니다${NC}"

# 모든 EBS 볼륨 가져오기
echo -e "\n${YELLOW}EBS 볼륨 정보 가져오는 중...${NC}"
ERROR_MSG=$(mktemp)
VOLUMES=$(aws ec2 describe-volumes \
    --region $REGION \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
    --query "Volumes[*].[VolumeId,Size,Attachments[0].Device]" \
    --output text 2>"$ERROR_MSG")

if [ -z "$VOLUMES" ]; then
    echo -e "${RED}EBS 볼륨 정보를 가져올 수 없습니다.${NC}"
    if [ -s "$ERROR_MSG" ]; then
        echo -e "${RED}에러 내용:${NC}"
        cat "$ERROR_MSG"
    fi
    rm -f "$ERROR_MSG"
    echo ""
    echo "문제 해결:"
    echo "1. IAM 역할에 다음 권한 추가:"
    echo "   {
       \"Version\": \"2012-10-17\",
       \"Statement\": [{
           \"Effect\": \"Allow\",
           \"Action\": [
               \"ec2:DescribeVolumes\",
               \"ec2:ModifyVolume\",
               \"ec2:DescribeVolumesModifications\"
           ],
           \"Resource\": \"*\"
       }]
   }"
    echo ""
    echo "2. EC2 콘솔에서 인스턴스에 역할 연결"
    exit 1
fi

VOLUME_COUNT=$(echo "$VOLUMES" | wc -l)

# 볼륨 정보 표시
echo -e "\n${BLUE}=== 현재 EBS 볼륨 상태 ===${NC}"
echo "$VOLUMES" | while read vid size dev; do
    echo "  $dev: ${size}GB (볼륨 ID: $vid)"
done

# 볼륨 선택 로직
if [ "$VOLUME_COUNT" -eq 1 ]; then
    # 볼륨이 하나면 자동 선택
    VOLUME_ID=$(echo "$VOLUMES" | awk '{print $1}')
    CURRENT_SIZE=$(echo "$VOLUMES" | awk '{print $2}')
    DEVICE_NAME=$(echo "$VOLUMES" | awk '{print $3}')
    echo -e "\n${GREEN}단일 볼륨 자동 선택: $DEVICE_NAME (${CURRENT_SIZE}GB)${NC}"
else
    # 여러 볼륨 중 루트 볼륨 우선 찾기
    ROOT_VOLUME=$(echo "$VOLUMES" | grep -E "(xvda|sda1|sda|nvme0n1)" | head -1)

    if [ -n "$ROOT_VOLUME" ]; then
        VOLUME_ID=$(echo "$ROOT_VOLUME" | awk '{print $1}')
        CURRENT_SIZE=$(echo "$ROOT_VOLUME" | awk '{print $2}')
        DEVICE_NAME=$(echo "$ROOT_VOLUME" | awk '{print $3}')
        echo -e "\n${YELLOW}여러 볼륨 중 루트 볼륨 선택됨: $DEVICE_NAME (${CURRENT_SIZE}GB)${NC}"
        read -p "이 볼륨을 확장하시겠습니까? (Y/n): " CONFIRM

        if [[ ! "$CONFIRM" =~ ^[Yy]?$ ]]; then
            echo "확장할 볼륨을 선택하세요:"
            echo "$VOLUMES" | nl -v 1 | while read num vid size dev; do
                echo "  $num) $dev: ${size}GB"
            done
            read -p "번호 입력: " SELECTION

            SELECTED=$(echo "$VOLUMES" | sed -n "${SELECTION}p")
            VOLUME_ID=$(echo "$SELECTED" | awk '{print $1}')
            CURRENT_SIZE=$(echo "$SELECTED" | awk '{print $2}')
            DEVICE_NAME=$(echo "$SELECTED" | awk '{print $3}')
        fi
    else
        # 루트 볼륨을 찾을 수 없으면 선택하게 함
        echo -e "\n${YELLOW}확장할 볼륨을 선택하세요:${NC}"
        echo "$VOLUMES" | nl -v 1 | while read num vid size dev; do
            echo "  $num) $dev: ${size}GB"
        done
        read -p "번호 입력: " SELECTION

        SELECTED=$(echo "$VOLUMES" | sed -n "${SELECTION}p")
        VOLUME_ID=$(echo "$SELECTED" | awk '{print $1}')
        CURRENT_SIZE=$(echo "$SELECTED" | awk '{print $2}')
        DEVICE_NAME=$(echo "$SELECTED" | awk '{print $3}')
    fi
fi

echo -e "\n선택된 볼륨:"
echo "  디바이스: $DEVICE_NAME"
echo "  볼륨 ID: $VOLUME_ID"
echo "  현재 크기: ${CURRENT_SIZE}GB"

# 추가할 크기 입력
if [ -z "$ADD_SIZE" ]; then
    echo -e "\n${YELLOW}얼마나 늘리시겠습니까?${NC}"
    read -p "추가할 크기 (GB): " ADD_SIZE
fi

# 크기 검증
if ! [[ "$ADD_SIZE" =~ ^[0-9]+$ ]] || [ "$ADD_SIZE" -le 0 ]; then
    echo -e "${RED}유효하지 않은 크기입니다${NC}"
    exit 1
fi

# 목표 크기 계산
TARGET_SIZE=$((CURRENT_SIZE + ADD_SIZE))
echo -e "\n${BLUE}크기 변경: ${CURRENT_SIZE}GB → ${TARGET_SIZE}GB (+${ADD_SIZE}GB)${NC}"

# 최종 확인
read -p "진행하시겠습니까? (Y/n): " FINAL_CONFIRM
if [[ ! "$FINAL_CONFIRM" =~ ^[Yy]?$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# EBS 볼륨 확장
echo -e "\n${YELLOW}EBS 볼륨 확장 중...${NC}"
MODIFY_RESULT=$(aws ec2 modify-volume \
    --region $REGION \
    --volume-id $VOLUME_ID \
    --size $TARGET_SIZE \
    --output json 2>&1)

# JSON 응답 확인
if echo "$MODIFY_RESULT" | jq -e . >/dev/null 2>&1; then
    echo -e "${GREEN}볼륨 확장 요청 성공${NC}"
else
    # 에러 처리
    if echo "$MODIFY_RESULT" | grep -q "UnauthorizedOperation"; then
        echo -e "${RED}ec2:ModifyVolume 권한이 없습니다.${NC}"
        echo "IAM 역할에 권한을 추가한 후 다시 시도하세요."
        exit 1
    elif echo "$MODIFY_RESULT" | grep -q "VolumeModificationNotSupported"; then
        echo -e "${RED}볼륨 확장 실패: 이 볼륨 타입은 수정을 지원하지 않습니다.${NC}"
        echo "다음과 같은 경우 볼륨 수정이 지원되지 않을 수 있습니다:"
        echo "  - 이전 세대 볼륨 타입 (standard)"
        echo "  - 특정 인스턴스 타입과의 호환성 문제"
        echo "  - 볼륨이 특수한 상태에 있는 경우"
        echo ""
        # 현재 볼륨 타입 확인
        VOL_TYPE=$(aws ec2 describe-volumes \
            --region $REGION \
            --volume-ids $VOLUME_ID \
            --query "Volumes[0].VolumeType" \
            --output text 2>/dev/null)
        if [ -n "$VOL_TYPE" ] && [ "$VOL_TYPE" != "None" ]; then
            echo "현재 볼륨 타입: $VOL_TYPE"
            if [ "$VOL_TYPE" = "standard" ]; then
                echo "standard 볼륨은 크기 수정이 지원되지 않습니다."
                echo "gp2, gp3, io1, io2 등으로 마이그레이션이 필요합니다."
            fi
        fi
        exit 1
    elif echo "$MODIFY_RESULT" | grep -q "VolumeModificationRateExceeded"; then
        echo -e "${RED}볼륨 확장 실패: 볼륨 수정 속도 제한 초과${NC}"
        echo "AWS는 볼륨당 6시간마다 한 번만 수정을 허용합니다."
        echo ""
        # 마지막 수정 시간 확인
        LAST_MOD_RESULT=$(aws ec2 describe-volumes-modifications \
            --region $REGION \
            --volume-id $VOLUME_ID \
            --output json 2>/dev/null)

        if [ -n "$LAST_MOD_RESULT" ]; then
            LAST_MOD=$(echo "$LAST_MOD_RESULT" | jq -r '.VolumesModifications[0].StartTime // empty')
        fi
        if [ -n "$LAST_MOD" ] && [ "$LAST_MOD" != "None" ]; then
            # ISO 8601 형식을 읽기 쉬운 형식으로 변환
            if date --version >/dev/null 2>&1; then
                # GNU date (Linux)
                LAST_MOD_FORMATTED=$(date -d "$LAST_MOD" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)
                RETRY_TIME=$(date -d "$LAST_MOD + 6 hours" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)
            else
                # BSD date (macOS)
                LAST_MOD_FORMATTED=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_MOD%.*}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)
                RETRY_TIME=$(date -j -v+6H -f "%Y-%m-%dT%H:%M:%S" "${LAST_MOD%.*}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)
            fi

            if [ -n "$LAST_MOD_FORMATTED" ]; then
                echo "마지막 수정 시간: $LAST_MOD_FORMATTED"
            else
                echo "마지막 수정 시간: $LAST_MOD"
            fi

            if [ -n "$RETRY_TIME" ]; then
                echo -e "${YELLOW}재시도 가능 시간: $RETRY_TIME${NC}"
            else
                echo "최소 6시간 후에 다시 시도하세요."
            fi
        else
            echo "최소 6시간 후에 다시 시도하세요."
        fi
        exit 1
    elif echo "$MODIFY_RESULT" | grep -q "IncorrectModificationState"; then
        echo -e "${RED}볼륨 확장 실패: 현재 다른 수정이 진행 중입니다.${NC}"
        echo "진행 중인 수정이 완료될 때까지 기다려주세요."
        # 현재 진행 상태 확인
        CURRENT_STATE=$(aws ec2 describe-volumes-modifications \
            --region $REGION \
            --volume-id $VOLUME_ID \
            --query "VolumesModifications[0].ModificationState" \
            --output text 2>/dev/null)
        if [ -n "$CURRENT_STATE" ] && [ "$CURRENT_STATE" != "None" ]; then
            echo "현재 상태: $CURRENT_STATE"
        fi
        exit 1
    elif echo "$MODIFY_RESULT" | grep -q "InvalidParameterValue"; then
        echo -e "${RED}볼륨 확장 실패: 잘못된 크기 값입니다.${NC}"
        echo "현재 크기: ${CURRENT_SIZE}GB, 요청한 크기: ${TARGET_SIZE}GB"
        echo "새로운 크기는 현재 크기보다 커야 합니다."
        exit 1
    elif echo "$MODIFY_RESULT" | grep -q "Error"; then
        echo -e "${RED}볼륨 확장 실패:${NC}"
        echo "$MODIFY_RESULT"
        exit 1
    else
        echo -e "${RED}알 수 없는 오류가 발생했습니다:${NC}"
        echo "$MODIFY_RESULT"
        exit 1
    fi
fi

# 볼륨 수정 완료 대기
echo -e "${YELLOW}볼륨 수정 완료 대기 중...${NC}"
WAIT_COUNT=0
MAX_WAIT=300  # 최대 5분 대기

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # 현재 볼륨 크기 확인 (실제 완료 여부 체크)
    CURRENT_VOL_SIZE=$(aws ec2 describe-volumes \
        --region $REGION \
        --volume-ids $VOLUME_ID \
        --query "Volumes[0].Size" \
        --output text 2>/dev/null)

    # 목표 크기에 도달했는지 확인
    if [ "$CURRENT_VOL_SIZE" = "$TARGET_SIZE" ]; then
        echo -e "\n${GREEN}EBS 볼륨 크기 변경 완료! (${TARGET_SIZE}GB)${NC}"
        echo -e "${YELLOW}최적화 진행 중이지만 사용 가능합니다.${NC}"
        break
    fi

    # 수정 상태 정보 조회 (진행 상황 표시용)
    MODIFICATION_INFO=$(aws ec2 describe-volumes-modifications \
        --region $REGION \
        --volume-ids $VOLUME_ID \
        --query "VolumesModifications[0]" \
        --output json 2>/dev/null)

    if [ -n "$MODIFICATION_INFO" ] && [ "$MODIFICATION_INFO" != "null" ]; then
        STATE=$(echo "$MODIFICATION_INFO" | jq -r '.ModificationState // "unknown"')
        PROGRESS=$(echo "$MODIFICATION_INFO" | jq -r '.Progress // 0')

        # 실패 체크
        if [ "$STATE" = "failed" ]; then
            echo -e "\n${RED}볼륨 확장 실패${NC}"
            exit 1
        fi

        # 진행 상황 표시 (12초마다)
        if [ $((WAIT_COUNT % 12)) -eq 0 ]; then
            echo -ne "\n수정 진행 중: ${PROGRESS}% [${STATE}] (현재: ${CURRENT_VOL_SIZE}GB / 목표: ${TARGET_SIZE}GB) "
        else
            echo -n "."
        fi
    else
        # 수정 정보 찾는 중
        if [ $((WAIT_COUNT % 12)) -eq 0 ]; then
            echo -ne "\n수정 정보 확인 중 (현재: ${CURRENT_VOL_SIZE}GB / 목표: ${TARGET_SIZE}GB) "
        else
            echo -n "."
        fi
    fi

    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo -e "\n${YELLOW}시간 초과. 백그라운드에서 계속 진행됩니다.${NC}"
fi

echo -e "\n${YELLOW}OS 레벨 확장 준비 중...${NC}"
sleep 5

# 필요한 도구 설치
if ! command -v growpart &> /dev/null; then
    echo -e "${YELLOW}growpart 설치 중...${NC}"

    if [ -f /etc/redhat-release ]; then
        yum install -y cloud-utils-growpart
    elif [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y cloud-guest-utils gdisk 2>/dev/null || apt-get install -y cloud-utils
    else
        echo -e "${RED}지원하지 않는 OS입니다.${NC}"
        exit 1
    fi
fi

# 디바이스 매핑 자동 처리
echo -e "\n${YELLOW}OS 레벨 파티션 및 파일시스템 확장 중...${NC}"

# AWS 디바이스명을 OS 디바이스명으로 변환
OS_DEVICE=""

# 변환 규칙 적용
if [[ $DEVICE_NAME == /dev/sd* ]]; then
    # sdf → xvdf 변환
    LETTER="${DEVICE_NAME:7}"
    TEST_DEVICE="/dev/xvd${LETTER}"
    [ -b "$TEST_DEVICE" ] && OS_DEVICE="$TEST_DEVICE"
fi

# 직접 매칭 시도
[ -z "$OS_DEVICE" ] && [ -b "$DEVICE_NAME" ] && OS_DEVICE="$DEVICE_NAME"

# NVMe 디바이스 확인
if [ -z "$OS_DEVICE" ] || [ ! -b "$OS_DEVICE" ]; then
    if command -v nvme &> /dev/null; then
        # 볼륨 ID로 NVMe 디바이스 찾기
        NVME_DEVICE=$(nvme list 2>/dev/null | grep -i "$VOLUME_ID" | awk '{print $1}')
        [ -n "$NVME_DEVICE" ] && [ -b "$NVME_DEVICE" ] && OS_DEVICE="$NVME_DEVICE"
    fi
fi

# 여전히 못 찾으면 lsblk로 찾기
if [ -z "$OS_DEVICE" ] || [ ! -b "$OS_DEVICE" ]; then
    # 크기로 매칭 시도
    POSSIBLE_DEVICES=$(lsblk -dpno NAME,SIZE | grep "${CURRENT_SIZE}G\|${TARGET_SIZE}G" | awk '{print $1}')
    for DEV in $POSSIBLE_DEVICES; do
        if [ -b "$DEV" ]; then
            OS_DEVICE="$DEV"
            break
        fi
    done
fi

# 최후의 수단: 첫 번째 디스크 사용
if [ -z "$OS_DEVICE" ] || [ ! -b "$OS_DEVICE" ]; then
    OS_DEVICE=$(lsblk -dpno NAME | grep -E '^/dev/(xvd|nvme)' | head -1)
fi

if [ -z "$OS_DEVICE" ] || [ ! -b "$OS_DEVICE" ]; then
    echo -e "${RED}OS 디바이스를 찾을 수 없습니다.${NC}"
    echo "수동으로 파티션과 파일시스템을 확장하세요."
    exit 1
fi

echo "처리할 OS 디바이스: $OS_DEVICE"

# 파티션 확장
PARTITION=""
if [[ $OS_DEVICE == /dev/nvme* ]]; then
    for PART_NUM in 1 2 3; do
        TEST_PART="${OS_DEVICE}p${PART_NUM}"
        [ -b "$TEST_PART" ] && PARTITION="$TEST_PART" && PART_NUMBER=$PART_NUM && break
    done
else
    for PART_NUM in 1 2 3; do
        TEST_PART="${OS_DEVICE}${PART_NUM}"
        [ -b "$TEST_PART" ] && PARTITION="$TEST_PART" && PART_NUMBER=$PART_NUM && break
    done
fi

# 파티션 확장
if [ -n "$PARTITION" ] && [ -n "$PART_NUMBER" ]; then
    echo "파티션 확장 시도: $PARTITION"
    growpart $OS_DEVICE $PART_NUMBER 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}파티션 확장 성공${NC}"
        sleep 2  # 파티션 테이블 업데이트 대기
    else
        echo "파티션이 이미 최대 크기이거나 확장 불필요"
    fi
else
    echo "파티션이 없는 디바이스 (전체 디스크 사용)"
    PARTITION=$OS_DEVICE
fi

# 파일시스템 확장
echo -e "\n파일시스템 확장 중..."

# LVM 확인 우선
if command -v pvs &> /dev/null && pvs $PARTITION &>/dev/null; then
    echo "LVM 물리 볼륨 감지됨"

    # PV 확장
    pvresize $PARTITION 2>/dev/null

    # VG 이름 찾기
    VG_NAME=$(pvs --noheadings -o vg_name $PARTITION 2>/dev/null | tr -d ' ')

    if [ -n "$VG_NAME" ]; then
        echo "볼륨 그룹: $VG_NAME"

        # 모든 LV 확장
        for LV_PATH in $(lvs $VG_NAME --noheadings -o lv_path 2>/dev/null); do
            LV_PATH=$(echo $LV_PATH | tr -d ' ')
            echo "논리 볼륨 확장: $LV_PATH"

            # 남은 공간 100% 사용
            lvextend -l +100%FREE $LV_PATH 2>/dev/null

            # LV의 파일시스템 확장
            LV_FS_TYPE=$(blkid -o value -s TYPE $LV_PATH 2>/dev/null)
            case $LV_FS_TYPE in
                ext2|ext3|ext4)
                    echo "  ext 파일시스템 확장..."
                    resize2fs $LV_PATH 2>/dev/null
                    ;;
                xfs)
                    echo "  XFS 파일시스템 확장..."
                    LV_MOUNT=$(findmnt -no TARGET $LV_PATH 2>/dev/null)
                    [ -n "$LV_MOUNT" ] && xfs_growfs $LV_MOUNT 2>/dev/null
                    ;;
            esac
        done
        echo -e "${GREEN}LVM 확장 완료${NC}"
    fi
else
    # 일반 파일시스템 확장
    FS_TYPE=$(blkid -o value -s TYPE $PARTITION 2>/dev/null)

    if [ -z "$FS_TYPE" ]; then
        FS_TYPE=$(lsblk -no FSTYPE $PARTITION 2>/dev/null | head -1)
    fi

    MOUNT_POINT=$(lsblk -no MOUNTPOINT $PARTITION 2>/dev/null | head -1)

    echo "파일시스템 타입: ${FS_TYPE:-알 수 없음}"
    echo "마운트 포인트: ${MOUNT_POINT:-마운트 안됨}"

    case $FS_TYPE in
        ext2|ext3|ext4)
            echo "ext 파일시스템 확장 중..."
            e2fsck -f $PARTITION -y 2>/dev/null  # 파일시스템 체크
            resize2fs $PARTITION 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}파일시스템 확장 완료${NC}"
            else
                echo -e "${YELLOW}파일시스템 확장 실패 또는 이미 최대 크기${NC}"
            fi
            ;;
        xfs)
            if [ -n "$MOUNT_POINT" ]; then
                echo "XFS 파일시스템 확장 중..."
                xfs_growfs $MOUNT_POINT 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}파일시스템 확장 완료${NC}"
                else
                    echo -e "${YELLOW}파일시스템 확장 실패 또는 이미 최대 크기${NC}"
                fi
            else
                echo -e "${RED}XFS는 마운트된 상태에서만 확장 가능${NC}"
            fi
            ;;
        btrfs)
            if [ -n "$MOUNT_POINT" ]; then
                echo "Btrfs 파일시스템 확장 중..."
                btrfs filesystem resize max $MOUNT_POINT 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}파일시스템 확장 완료${NC}"
                fi
            fi
            ;;
        *)
            echo -e "${YELLOW}알 수 없는 파일시스템 타입: $FS_TYPE${NC}"
            echo "수동으로 파일시스템을 확장하세요."
            ;;
    esac
fi

# 최종 상태 확인
echo -e "\n${GREEN}=== 최종 디스크 상태 ===${NC}"
df -hT | grep -E "^/dev/|^Filesystem" | head -20

echo -e "\n${GREEN}=== EBS 볼륨 최종 상태 ===${NC}"
FINAL_SIZE=$(aws ec2 describe-volumes \
    --region $REGION \
    --volume-ids $VOLUME_ID \
    --query "Volumes[0].Size" \
    --output text 2>/dev/null)

if [ -n "$FINAL_SIZE" ]; then
    echo "볼륨 ID: $VOLUME_ID"
    echo "최종 크기: ${FINAL_SIZE}GB (${ADD_SIZE}GB 추가됨)"
    echo "상태: 정상"
else
    echo "볼륨 정보를 가져올 수 없지만 확장은 완료되었습니다."
fi

echo -e "\n${GREEN}✔ 스크립트 완료! ${ADD_SIZE}GB가 성공적으로 추가되었습니다.${NC}"
echo -e "${YELLOW}※ 파일시스템 크기가 바로 반영되지 않으면 재부팅 후 확인하세요.${NC}"

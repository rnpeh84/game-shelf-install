#!/usr/bin/env bash
# Interactive installer for a Game Shelf image published in hub.v.cller.com.
# It reads every answer from the terminal so it also works with curl | bash.
set -Eeuo pipefail
umask 077

REGISTRY=hub.v.cller.com
DEFAULT_PROJECT=game-platform
DEFAULT_IMAGE_VERSION=0.3.1
INSTALL_DIR_DEFAULT=$PWD
PROJECT_ARG=''
REPOSITORY_ARG=''
IMAGE_SELECTOR_ARG=''
INSTALL_DIR_ARG=''

usage() {
  cat <<'EOF'
Usage: bash install.sh [--project NAME] [--repository NAME] [--image TAG|sha256:DIGEST] [--dir PATH]

Installs the platform image from hub.v.cller.com using Docker Compose.
The current working directory is the default install directory.
Press Enter at a prompt to accept its displayed default. On first install,
an empty admin password is generated and shown after a successful health check.
All passwords are entered at a terminal, never as arguments. The first run
bind-mounts a persistent host directory for the SQLite database and uploaded games.
Run the same command again with a new image tag or digest to update the service.
EOF
}

die() { printf '오류: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while (($#)); do
  case "$1" in
    --project|--repository|--image|--dir)
      (($# >= 2)) || die "$1 값이 없습니다."
      case "$1" in
        --project) PROJECT_ARG=$2 ;;
        --repository) REPOSITORY_ARG=$2 ;;
        --image) IMAGE_SELECTOR_ARG=$2 ;;
        --dir) INSTALL_DIR_ARG=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "알 수 없는 인수: $1" ;;
  esac
done

if ! ( : </dev/tty >/dev/tty ) 2>/dev/null; then
  die '대화형 터미널이 필요합니다. SSH -t 등을 사용해 다시 실행하세요.'
fi
command -v docker >/dev/null 2>&1 || die 'Docker가 필요합니다.'
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2가 필요합니다.'

ask() {
  local prompt=$1 default=${2-} display=${3-${2-}} answer
  if [[ -n $display ]]; then
    printf '%s [%s]: ' "$prompt" "$display" >/dev/tty
  else
    printf '%s: ' "$prompt" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || die '입력을 읽지 못했습니다.'
  REPLY=${answer:-$default}
}

ask_secret() {
  local prompt=$1 answer
  printf '%s: ' "$prompt" >/dev/tty
  IFS= read -r -s answer </dev/tty || die '비밀 입력을 읽지 못했습니다.'
  printf '\n' >/dev/tty
  REPLY=$answer
}

valid_segment() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]*$ ]] && [[ $1 != *..* ]]; }
valid_tag() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_digest() { [[ $1 =~ ^sha256:[0-9a-fA-F]{64}$ ]]; }
valid_domain() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]] && [[ $1 != *..* && $1 != *.-* && $1 != *-.* ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
check_admin_password() {
  local value=$1 allowed='^[A-Za-z0-9._@%+:/=!^?*&-]+$' invalid=0
  if ((${#value} < 12)); then
    printf '비밀번호가 %s자입니다. 최소 12자여야 합니다.\n' "${#value}" >/dev/tty
    invalid=1
  fi
  if [[ ! $value =~ $allowed ]]; then
    printf '사용할 수 없는 문자가 있습니다. 영문·숫자와 . _ @ %% + : / = - ! ^ ? * & 만 사용할 수 있습니다.\n' >/dev/tty
    invalid=1
  fi
  ((invalid == 0))
}
prompt_admin_password() {
  while :; do
    ask_secret '관리자 비밀번호 (Enter: 자동 생성)'
    ADMIN_PASSWORD=$REPLY
    if [[ -z $ADMIN_PASSWORD ]]; then
      ADMIN_PASSWORD=$(openssl rand -hex 16) || die '관리자 비밀번호 생성에 실패했습니다.'
      GENERATED_ADMIN_PASSWORD=1
      info '관리자 비밀번호를 자동 생성했습니다. 설치 성공 후 터미널에 한 번 표시합니다.'
      return 0
    fi
    if check_admin_password "$ADMIN_PASSWORD"; then
      return 0
    fi
    printf '비밀번호를 다시 입력하거나 Enter를 눌러 자동 생성하세요.\n' >/dev/tty
  done
}
valid_path() {
  local pattern='^/[A-Za-z0-9_./ -]+$'
  [[ $1 =~ $pattern && $1 != *..* ]]
}

# Read only keys that this installer writes; never evaluate the .env file as shell code.
stored() {
  local key=$1 file=$2
  [[ -f $file ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

ask '설치 디렉터리' "${INSTALL_DIR_ARG:-$INSTALL_DIR_DEFAULT}"
INSTALL_DIR=$REPLY
valid_path "$INSTALL_DIR" || die '설치 경로는 절대 경로로 입력하세요. 영문·숫자·공백·_·-·.만 허용합니다.'
[[ ! -L $INSTALL_DIR ]] || die '설치 디렉터리 심볼릭 링크는 허용하지 않습니다.'
mkdir -p "$INSTALL_DIR"
INSTALL_DIR=$(cd "$INSTALL_DIR" && pwd -P)
ENV_FILE=$INSTALL_DIR/.env
COMPOSE_FILE=$INSTALL_DIR/compose.yaml
[[ ! -L $ENV_FILE && ! -L $COMPOSE_FILE ]] || die '기존 설정 파일의 심볼릭 링크는 허용하지 않습니다.'
if [[ -f $ENV_FILE && ! -f $COMPOSE_FILE ]] || [[ ! -f $ENV_FILE && -f $COMPOSE_FILE ]]; then
  die '설치 디렉터리에 설정 파일이 일부만 있습니다. 수동으로 확인해 주세요.'
fi
EXISTING=0
if [[ -f $ENV_FILE ]]; then
  EXISTING=1
  [[ -r $ENV_FILE ]] || die '기존 .env를 읽을 수 없습니다.'
fi

PROJECT_DEFAULT=${PROJECT_ARG:-$(stored HARBOR_PROJECT "$ENV_FILE")}
ask 'Harbor 프로젝트' "${PROJECT_DEFAULT:-$DEFAULT_PROJECT}"
HARBOR_PROJECT=$REPLY
valid_segment "$HARBOR_PROJECT" || die 'Harbor 프로젝트 이름은 소문자, 숫자, 점, 밑줄, 하이픈만 허용합니다.'
REPOSITORY_DEFAULT=${REPOSITORY_ARG:-$(stored IMAGE_REPOSITORY "$ENV_FILE")}
ask '이미지 저장소' "${REPOSITORY_DEFAULT:-game-shelf}"
IMAGE_REPOSITORY=$REPLY
valid_segment "$IMAGE_REPOSITORY" || die '이미지 저장소 이름이 올바르지 않습니다.'
IMAGE_SELECTOR_DEFAULT=${IMAGE_SELECTOR_ARG:-$(stored IMAGE_SELECTOR "$ENV_FILE")}
ask '이미지 버전 태그 또는 sha256:다이제스트' "${IMAGE_SELECTOR_DEFAULT:-$DEFAULT_IMAGE_VERSION}"
IMAGE_SELECTOR=$REPLY
if valid_digest "$IMAGE_SELECTOR"; then
  IMAGE_REF="$REGISTRY/$HARBOR_PROJECT/$IMAGE_REPOSITORY@$IMAGE_SELECTOR"
elif valid_tag "$IMAGE_SELECTOR"; then
  IMAGE_REF="$REGISTRY/$HARBOR_PROJECT/$IMAGE_REPOSITORY:$IMAGE_SELECTOR"
else
  die '이미지 선택은 태그 또는 sha256:64자리 해시여야 합니다.'
fi

STACK_DEFAULT=$(stored STACK_NAME "$ENV_FILE")
ask 'Compose 스택 이름' "${STACK_DEFAULT:-game-shelf}"
STACK_NAME=$REPLY
[[ $STACK_NAME =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die '스택 이름은 소문자, 숫자, 밑줄, 하이픈만 허용합니다.'
OLD_STACK=$(stored STACK_NAME "$ENV_FILE")
if ((EXISTING)) && [[ $STACK_NAME != "$OLD_STACK" ]]; then
  die '재설치 시 스택 이름을 바꿀 수 없습니다. 기존 컨테이너를 안전하게 갱신하려면 같은 이름을 사용하세요.'
fi
if ((!EXISTING)) && [[ -n $(docker ps -aq --filter "label=com.docker.compose.project=$STACK_NAME") ]]; then
  die '같은 Compose 스택 이름의 컨테이너가 이미 있습니다. 설치 디렉터리를 확인하거나 다른 이름을 사용하세요.'
fi

PORT_DEFAULT=$(stored PLATFORM_PORT "$ENV_FILE")
ask '호스트 HTTP 포트' "${PORT_DEFAULT:-4100}"
PLATFORM_PORT=$REPLY
valid_port "$PLATFORM_PORT" || die '호스트 포트는 1~65535 범위여야 합니다.'
ORIGIN_DEFAULT=$(stored PLATFORM_ORIGIN "$ENV_FILE")
ask '플랫폼 주소 (http:// 또는 https://)' "${ORIGIN_DEFAULT:-http://localhost:$PLATFORM_PORT}"
PLATFORM_ORIGIN=$REPLY
if [[ $PLATFORM_ORIGIN =~ ^https?://([a-zA-Z0-9][a-zA-Z0-9.-]*)(:([0-9]{1,5}))?$ ]]; then
  ORIGIN_HOST=${BASH_REMATCH[1]}
  ORIGIN_PORT=${BASH_REMATCH[3]}
else
  die '플랫폼 주소는 경로 없는 http(s) origin이어야 합니다.'
fi
valid_domain "$ORIGIN_HOST" || die '플랫폼 주소의 호스트 이름이 올바르지 않습니다.'
[[ -z $ORIGIN_PORT ]] || valid_port "$ORIGIN_PORT" || die '플랫폼 주소의 포트가 올바르지 않습니다.'
GAME_DOMAIN_DEFAULT=$(stored GAME_BASE_DOMAIN "$ENV_FILE")
ask '게임 실행 기본 도메인 (예: games.example.com)' "${GAME_DOMAIN_DEFAULT:-games.localhost}"
GAME_BASE_DOMAIN=$REPLY
valid_domain "$GAME_BASE_DOMAIN" || die '게임 기본 도메인이 올바르지 않습니다.'
OLD_GAME_BASE_DOMAIN=$(stored GAME_BASE_DOMAIN "$ENV_FILE")
if ((EXISTING)) && [[ $GAME_BASE_DOMAIN != "$OLD_GAME_BASE_DOMAIN" ]]; then
  die '게임 도메인은 브라우저 저장 데이터의 origin입니다. 기존 설치에서 자동 변경할 수 없습니다.'
fi
DATA_PATH_DEFAULT=$(stored DATA_PATH "$ENV_FILE")
ask 'DB·게임 파일 저장 경로 (절대 경로)' "${DATA_PATH_DEFAULT:-$INSTALL_DIR/data}"
DATA_PATH=$REPLY
valid_path "$DATA_PATH" || die '데이터 경로는 절대 경로로 입력하세요. 영문·숫자·공백·_·-·.만 허용합니다.'
[[ ! -L $DATA_PATH ]] || die '데이터 디렉터리 심볼릭 링크는 허용하지 않습니다.'
NEW_DATA_PATH=0
[[ -e $DATA_PATH ]] || NEW_DATA_PATH=1
if ((EXISTING && NEW_DATA_PATH)); then
  die '기존 데이터 디렉터리가 없습니다. DB와 게임 파일을 복원한 뒤 다시 실행하세요.'
fi
mkdir -p "$DATA_PATH"
DATA_PATH=$(cd "$DATA_PATH" && pwd -P)
[[ $DATA_PATH != / ]] || die '루트 디렉터리를 데이터 경로로 사용할 수 없습니다.'
if [[ $INSTALL_DIR == "$DATA_PATH" || $INSTALL_DIR == "$DATA_PATH/"* ]]; then
  die '데이터 경로가 설치 설정 디렉터리를 포함하면 관리자 비밀키가 컨테이너에 노출됩니다.'
fi
OLD_DATA_PATH=$(stored DATA_PATH "$ENV_FILE")
if ((EXISTING)) && [[ $DATA_PATH != "$OLD_DATA_PATH" ]]; then
  die '재설치 시 데이터 디렉터리를 바꿀 수 없습니다. 기존 DB와 게임 파일이 분리됩니다.'
fi
if ((EXISTING)) && [[ ! -f $DATA_PATH/catalog.sqlite ]]; then
  die '기존 SQLite DB가 없습니다. 빈 DB로 재시작하지 않도록 설치를 중단합니다.'
fi

GENERATED_ADMIN_PASSWORD=0
if ((EXISTING)); then
  ADMIN_PASSWORD=$(stored ADMIN_PASSWORD "$ENV_FILE")
  PREVIEW_SECRET=$(stored PREVIEW_SECRET "$ENV_FILE")
  [[ ${#PREVIEW_SECRET} -ge 32 ]] || die '기존 미리보기 비밀키가 올바르지 않습니다.'
  if check_admin_password "$ADMIN_PASSWORD"; then
    info '기존 관리자 비밀번호와 미리보기 키를 유지합니다.'
  else
    printf '기존 %s 의 ADMIN_PASSWORD를 사용할 수 없습니다. 새 비밀번호를 입력하세요.\n' "$ENV_FILE" >/dev/tty
    command -v openssl >/dev/null 2>&1 || die '자동 비밀번호 생성에 openssl이 필요합니다.'
    prompt_admin_password
  fi
else
  command -v openssl >/dev/null 2>&1 || die '첫 설치에는 openssl이 필요합니다.'
  info '관리자 비밀번호는 12자 이상입니다. Enter를 누르면 자동 생성합니다.'
  prompt_admin_password
  PREVIEW_SECRET=$(openssl rand -hex 32) || die '미리보기 키 생성에 실패했습니다.'
fi

ask 'Harbor 사용자 이름' '' '기존 Docker 로그인 사용'
HARBOR_USER=$REPLY
if [[ -n $HARBOR_USER ]]; then
  [[ $HARBOR_USER =~ ^[A-Za-z0-9_][A-Za-z0-9_.@+\$-]*$ ]] || die 'Harbor 사용자 이름 형식이 올바르지 않습니다.'
  ask_secret 'Harbor 비밀번호 또는 로봇 계정 토큰'
  HARBOR_PASSWORD=$REPLY
  [[ -n $HARBOR_PASSWORD ]] || die 'Harbor 비밀번호가 비어 있습니다.'
  printf '%s' "$HARBOR_PASSWORD" | docker login "$REGISTRY" --username "$HARBOR_USER" --password-stdin >/dev/null || die 'Harbor 로그인에 실패했습니다.'
  unset HARBOR_PASSWORD
fi

info "이미지를 확인합니다: $IMAGE_REF"
docker pull "$IMAGE_REF" || die '이미지 다운로드에 실패했습니다. 기존 서비스는 그대로 유지됩니다.'
IMAGE_DIGEST=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE_REF" 2>/dev/null \
  | awk -v prefix="$REGISTRY/$HARBOR_PROJECT/$IMAGE_REPOSITORY@sha256:" 'index($0, prefix) == 1 { print; exit }')
[[ -n $IMAGE_DIGEST ]] || die '받은 이미지의 다이제스트를 확인할 수 없습니다.'
IMAGE_REF=$IMAGE_DIGEST
# A new empty host directory is prepared for the image's non-root node process.
# Never change ownership of an existing directory or its contents.
if ((NEW_DATA_PATH)); then
  [[ -z $(ls -A "$DATA_PATH") ]] || die '새 데이터 디렉터리가 비어 있지 않아 소유권을 변경하지 않습니다.'
  docker run --rm --user 0:0 --mount "type=bind,src=$DATA_PATH,dst=/data" \
    --entrypoint chown "$IMAGE_REF" node:node /data >/dev/null \
    || die '새 데이터 디렉터리의 소유권 설정에 실패했습니다.'
fi
docker run --rm --mount "type=bind,src=$DATA_PATH,dst=/data" --entrypoint node "$IMAGE_REF" \
  -e "const fs=require('fs'); const dir=fs.mkdtempSync('/data/.gameshelf-install-'); fs.rmdirSync(dir)" >/dev/null \
  || die '컨테이너가 데이터 디렉터리에 쓸 수 없습니다. 기존 경로의 권한을 확인하세요.'
# The generated stack is self-contained; SQLite and uploaded games live in the
# selected bind mount. An OCI image update never replaces those files.
TMP_ENV=$(mktemp "$INSTALL_DIR/.env.XXXXXX")
TMP_COMPOSE=$(mktemp "$INSTALL_DIR/compose.yaml.XXXXXX")
BACKUP_ENV=''
BACKUP_COMPOSE=''
COMMITTED=0
DEPLOYED=0
cleanup() {
  rm -f "$TMP_ENV" "$TMP_COMPOSE"
  if ((COMMITTED && !DEPLOYED)); then
    info '새 버전 실행에 실패하여 이전 설정으로 복구합니다.' >&2
    if ((EXISTING)); then
      cp "$BACKUP_ENV" "$ENV_FILE"
      cp "$BACKUP_COMPOSE" "$COMPOSE_FILE"
      docker compose -p "$STACK_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-build --pull never >&2 || true
    else
      docker compose -p "$STACK_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down >&2 || true
      rm -f "$ENV_FILE" "$COMPOSE_FILE"
    fi
  fi
  [[ -z $BACKUP_ENV ]] || rm -f "$BACKUP_ENV"
  [[ -z $BACKUP_COMPOSE ]] || rm -f "$BACKUP_COMPOSE"
}
trap cleanup EXIT

cat >"$TMP_ENV" <<EOF
HARBOR_PROJECT=$HARBOR_PROJECT
IMAGE_REPOSITORY=$IMAGE_REPOSITORY
IMAGE_SELECTOR=$IMAGE_SELECTOR
IMAGE_REF=$IMAGE_REF
STACK_NAME=$STACK_NAME
PLATFORM_ORIGIN=$PLATFORM_ORIGIN
GAME_BASE_DOMAIN=$GAME_BASE_DOMAIN
PLATFORM_PORT=$PLATFORM_PORT
DATA_PATH=$DATA_PATH
ADMIN_PASSWORD=$ADMIN_PASSWORD
PREVIEW_SECRET=$PREVIEW_SECRET
EOF

cat >"$TMP_COMPOSE" <<'EOF'
services:
  platform:
    image: ${IMAGE_REF:?Set IMAGE_REF}
    ports:
      - "${PLATFORM_PORT:?Set PLATFORM_PORT}:3000"
    environment:
      NODE_ENV: production
      PORT: "3000"
      DATA_DIR: /data
      PLATFORM_ORIGIN: ${PLATFORM_ORIGIN:?Set PLATFORM_ORIGIN}
      GAME_BASE_DOMAIN: ${GAME_BASE_DOMAIN:?Set GAME_BASE_DOMAIN}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:?Set ADMIN_PASSWORD}
      PREVIEW_SECRET: ${PREVIEW_SECRET:?Set PREVIEW_SECRET}
    volumes:
      - "${DATA_PATH:?Set DATA_PATH}:/data"
    restart: unless-stopped
EOF

docker compose -p "$STACK_NAME" -f "$TMP_COMPOSE" --env-file "$TMP_ENV" config -q || die 'Compose 설정 검증에 실패했습니다.'
if ((EXISTING)); then
  BACKUP_ENV=$(mktemp "$INSTALL_DIR/.env.backup.XXXXXX")
  BACKUP_COMPOSE=$(mktemp "$INSTALL_DIR/compose.yaml.backup.XXXXXX")
  cp "$ENV_FILE" "$BACKUP_ENV"
  cp "$COMPOSE_FILE" "$BACKUP_COMPOSE"
fi
mv -f "$TMP_ENV" "$ENV_FILE"
mv -f "$TMP_COMPOSE" "$COMPOSE_FILE"
COMMITTED=1
docker compose -p "$STACK_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --no-build --pull never || die '컨테이너 시작에 실패했습니다.'

CONTAINER_ID=$(docker compose -p "$STACK_NAME" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -q platform) || die '컨테이너 상태를 읽지 못했습니다.'
[[ -n $CONTAINER_ID ]] || die '플랫폼 컨테이너가 없습니다.'
info '헬스 체크를 기다립니다.'
for ((attempt=1; attempt<=45; attempt++)); do
  HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER_ID" 2>/dev/null || true)
  if [[ $HEALTH == healthy ]]; then
    DEPLOYED=1
    break
  fi
  [[ $HEALTH != unhealthy || $attempt -lt 45 ]] || break
  sleep 2
done
((DEPLOYED)) || die '헬스 체크가 통과하지 못했습니다. 컨테이너 로그를 확인하세요.'
info "설치 완료: $PLATFORM_ORIGIN"
info "로그인: $PLATFORM_ORIGIN/login"
if ((!EXISTING)); then
  info '최초 관리자 아이디: admin'
else
  info '기존 관리자는 첫 로그인에서 관리자 계정 연결을 완료하세요.'
fi
if ((GENERATED_ADMIN_PASSWORD)); then
  printf '관리자 비밀번호 (한 번만 표시): %s\n' "$ADMIN_PASSWORD" >/dev/tty
  info "비밀번호는 $ENV_FILE 에도 저장되어 있습니다."
fi
info "이미지: $IMAGE_REF"
[[ -z $IMAGE_DIGEST || $IMAGE_DIGEST == '<no value>' ]] || info "확인된 이미지 다이제스트: $IMAGE_DIGEST"
info "영속 데이터: $DATA_PATH (/data)"
info '운영 도메인에서는 HTTPS와 게임별 서브도메인 DNS/역방향 프록시를 별도로 구성해야 합니다.'

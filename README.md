# Game Shelf 설치 스크립트

이 저장소에는 Game Shelf 플랫폼 설치 스크립트만 공개한다. 플랫폼 소스와 게임 파일은 포함하지 않는다.

Docker Engine, Docker Compose v2, curl, OpenSSL이 필요하다. Harbor의 `game-platform` 프로젝트가 비공개이므로 설치할 서버에서 먼저 `docker login hub.v.cller.com`을 실행한다.

```bash
mkdir -p ~/docker/game-shelf && cd ~/docker/game-shelf
docker login hub.v.cller.com
curl -fsSLo install.sh https://raw.githubusercontent.com/rnpeh84/game-shelf-install/v0.1.1/install.sh &&
  test "$(openssl dgst -sha256 install.sh | awk '{print $NF}')" = "d83a23128c3757fe62a18118180bb1fb9e6ad3bab80d1a437183f1c3aeaaf709" &&
  bash install.sh --project game-platform --image sha256:e1d17d8932452ba5ef0dc3ed3e2ce425b24cd79f7196495039837ee2faa247fd
```

설치 디렉터리의 기본값은 스크립트를 실행한 현재 폴더다. Enter를 누르면 그 폴더에 `.env`, `compose.yaml`, `data/`가 생긴다. 실행 시 주소, 포트, 게임 도메인, 영속 데이터 위치, 관리자 비밀번호 등을 묻는다. 데이터베이스는 영속 데이터 폴더에 SQLite로 생성된다. 이미지와 설치 스크립트는 별도로 버전 관리하며, 위 주소는 `v0.1.1` 릴리스에 고정된다.

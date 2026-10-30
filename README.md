# Game Shelf 설치 스크립트

이 저장소에는 Game Shelf 플랫폼 설치 스크립트만 공개한다. 플랫폼 소스와 게임 파일은 포함하지 않는다.

설치 서버에는 Docker Engine, Docker Compose v2, curl, OpenSSL이 필요하다. Harbor의 `game-platform` 프로젝트가 비공개이므로 먼저 `docker login hub.v.cller.com`을 실행한다.

```bash
mkdir -p ~/docker/game-shelf && cd ~/docker/game-shelf
docker login hub.v.cller.com
curl -fsSLo install.sh https://raw.githubusercontent.com/rnpeh84/game-shelf-install/v0.3.2/install.sh &&
  test "$(openssl dgst -sha256 install.sh | awk '{print $NF}')" = "667baad8a9ef04ea1c8d723590dd5d0391ab6b78bbbf9dafde8e832b39e76f8a" &&
  bash install.sh
```

설치 질문에서 Enter를 누르면 기본값을 사용한다. 설치 경로는 스크립트를 실행한 현재 폴더, 데이터 경로는 그 폴더의 `data/`다. 두 경로 모두 설치 중 바꿀 수 있다. 관리자 비밀번호는 직접 입력하거나 비워 두면 자동 생성한다. 길이나 문자 조건에 맞지 않으면 이유를 보여 주고 다시 묻는다. 자동 생성값은 **설치 성공 후 터미널에 한 번 표시**하며 소유자만 읽을 수 있는 `.env`에도 저장한다. 이후 재실행 시 기존 비밀번호와 데이터는 유지된다.

기본 플랫폼 이미지는 `0.3.2`이고, 스크립트가 pull한 이미지의 digest를 Compose 설정에 고정한다. URL은 `v0.3.2` 릴리스에 고정된다. 신규 설치의 최초 관리자 아이디는 `admin`이다. 기존 `0.2.0` 데이터로 갱신하면 공통 로그인 화면에서 기존 관리자 비밀번호와 새 관리자 아이디를 한 번 연결한다.

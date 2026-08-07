# PR 코드 이해도 검증 게이트 서비스 기획안

> 코드 작성자가 자신의 변경사항을 실제로 이해했는지 퀴즈로 검증한 뒤에만 리뷰 단계로 진입시키는 사내 개발 프로세스 도구

| 항목            | 내용                                                                               |
| --------------- | ---------------------------------------------------------------------------------- |
| 프로젝트 코드명 | (가칭) **PRuiz**                                                                   |
| 작성일          | 2026-08-06                                                                         |
| 문서 버전       | v1.0                                                                               |
| 기술 스택       | nginx · Vite(React+TS) · **Python / FastAPI** · LangChain · MySQL · Redis · Docker |

---

## 1. 배경 및 문제 정의

### 1.1 배경

AI 코딩 도구 도입 이후 코드 생산량은 늘었지만, **작성자 본인이 자기 PR의 내용을 설명하지 못하는 경우**가 발생한다. 기존 코드 리뷰는 "작성자는 자신의 diff를 이해하고 있다"는 암묵적 전제 위에 설계되어 있는데, 이 전제가 깨지면 리뷰어에게 검증 부담이 전가되고 결과적으로 형식적 승인(rubber-stamp approval)이 늘어난다.

### 1.2 해결하려는 문제

| 문제                    | 현재 상태              | 목표 상태                     |
| ----------------------- | ---------------------- | ----------------------------- |
| 작성자의 코드 이해 부족 | 검증 수단 없음         | PR 단위 이해도 검증 통과 필수 |
| 리뷰어 부담 전가        | 리뷰어가 맥락까지 파악 | 작성자가 사전에 맥락 확보     |
| 형식적 승인             | 정성적 문제로 방치     | 게이트로 구조화               |

### 1.3 목표 (Goals)

- PR 생성 시 diff 기반 이해도 퀴즈를 자동 생성한다
- 퀴즈 통과 전에는 해당 PR이 **리뷰/머지 단계로 진행되지 못하게** 한다
- 팀원별·저장소별 이해도 추이를 가시화한다

### 1.4 명시적 비목표 (Non-Goals)

- **AI 코드 리뷰가 아니다.** 코드 품질·버그 지적은 범위 밖이다 (CodeRabbit, Qodo 등이 담당하는 영역)
- **부정행위 완전 차단은 불가능하다.** 작성자가 LLM에게 물어 답하는 것을 막을 수 없다. 본 도구는 **규율·습관 형성 도구**로 포지셔닝한다
- 시니어 리뷰어의 판단을 대체하지 않는다

### 1.5 성공 지표

- 퀴즈 1차 시도 통과율: 도입 4주 후 70~85% (95% 이상이면 문제가 너무 쉬움, 50% 이하면 병목)
- PR 생성 → 리뷰 요청까지 추가 지연: 중위값 10분 이내
- 이의제기(dispute) 인정률: 10% 이하 (초과 시 퀴즈 품질 문제)
- 팀원 만족도 조사: 도입 6주 후 "유용하다" 60% 이상

---

## 2. 핵심 설계 결정 (가장 중요한 섹션)

### 2.1 확인된 제약: GitHub은 "리뷰 요청" 행위를 차단할 수 없다

당초 구상은 "퀴즈를 통과해야 리뷰 요청 가능"이었으나, GitHub에는 **리뷰어 지정 행위를 막는 권한이나 설정이 존재하지 않는다.**

- 리뷰 요청 API(`POST /repos/{owner}/{repo}/pulls/{n}/requested_reviewers`)는 PR 작성자 및 collaborator 누구나 호출 가능
- 웹 UI의 Reviewers 사이드바는 항상 활성 상태
- 브랜치 보호 규칙(Ruleset)이 통제하는 것은 리뷰 요청이 아니라 **머지(merge)**

따라서 게이트 지점을 재설계한다.

### 2.2 채택 방식: 3중 게이트

#### ① 머지 게이트 — Commit Status API (주 게이트, 필수)

Commit Status API로 `proof/comprehension` 컨텍스트를 게시하고, 이를 Ruleset의 **required status check**로 등록한다. 외부 서비스가 커밋 상태를 표시할 수 있고, 필수 체크가 통과하지 않으면 머지가 차단된다.

| 게이트 상태      | Commit Status | PR에 표시되는 설명                  |
| ---------------- | ------------- | ----------------------------------- |
| 퀴즈 생성 중     | `pending`     | 이해도 퀴즈 생성 중…                |
| 응시 대기        | `pending`     | 퀴즈 응시 필요 (Details 링크)       |
| 통과             | `success`     | 이해도 검증 통과 (8/10)             |
| 실패·재응시 대기 | `failure`     | 재응시 가능 시각 표시               |
| 대상 아님        | `success`     | 검증 면제 (변경량 미달 / 제외 경로) |

`target_url`에 본 서비스의 퀴즈 응시 페이지 링크를 넣어 PR 화면에서 바로 진입하게 한다.

#### ② Draft 강제 — GraphQL (보조 게이트, 권장)

`pull_request.opened` 수신 시 `convertPullRequestToDraft` 뮤테이션으로 초안 전환한다. Draft 상태에서는 머지 버튼이 비활성이고 **CODEOWNERS 자동 리뷰 요청도 트리거되지 않는다.** 퀴즈 통과 시 `markPullRequestReadyForReview`로 승격한다.

이 방식이 원래 의도한 UX("리뷰 요청 자체를 막는다")에 가장 가깝다. 단, Draft 상태에서도 수동 리뷰어 지정은 가능하므로 ①과 병행해야 한다.

#### ③ 리뷰 요청 감지 후 안내 (게이트 아님, 안내용)

`pull_request` 웹훅의 `review_requested` 액션을 수신해, 미통과 상태이면 봇 코멘트로 퀴즈 링크를 안내한다.

> `DELETE requested_reviewers`로 강제 취소하는 방안은 **채택하지 않는다.** 웹훅 도착 시점에 리뷰어 알림은 이미 발송되었고, 사용자 조작과 경합(race)이 발생하며 무엇보다 "내가 한 조작이 유령처럼 되돌아가는" 경험이 강한 반발을 유발한다. 설정으로 opt-in만 제공한다.

### 2.3 감수하는 한계

- 저장소 admin 및 Ruleset bypass 권한자는 게이트를 우회할 수 있다 → 사내 규율 도구이므로 허용. 단 **우회 시 audit log에 기록하고 주간 리포트에 노출**한다
- Draft 전환은 작성자가 수동으로 되돌릴 수 있다 → ① 머지 게이트가 최종 방어선

---

## 3. 사용자 플로우

### 3.1 작성자(PR Author) 플로우

```
1. 개발자가 브랜치 푸시 후 PR 생성
        ↓
2. [자동] 서비스가 웹훅 수신
   → Draft로 전환
   → Commit Status: pending("퀴즈 생성 중")
   → 퀴즈 생성 작업 큐 적재
        ↓
3. [자동] 30초~2분 내 퀴즈 생성 완료
   → Commit Status: pending("퀴즈 응시 필요", target_url)
   → PR에 봇 코멘트로 응시 링크 게시
        ↓
4. 개발자가 GitHub 로그인으로 서비스 접속 → 퀴즈 응시 (5~8분)
        ↓
5-A. 통과 → Commit Status: success
          → Ready for review 승격
          → 리뷰어 지정 가능 / 머지 차단 해제
        ↓
5-B. 미통과 → 오답 해설 표시 + 재응시 쿨다운(기본 1분)
           → 재응시 시 문항 일부 교체(문항 풀에서 재추출)
```

### 3.2 예외 플로우

| 상황                                     | 처리                                                                                                                               |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| PR에 추가 커밋 푸시 (`synchronize`)      | 변경 라인 수가 임계치(기본 30줄) 미만이면 기존 통과 상태 유지. 초과 시 **추가분에 대한 보충 문항 2~3개**만 출제 (전체 재응시 아님) |
| 변경량이 최소 기준 미달 (기본 10줄)      | 자동 면제, `success` 처리                                                                                                          |
| 제외 경로만 변경 (lockfile, 자동생성 등) | 자동 면제                                                                                                                          |
| 퀴즈 생성 실패 (LLM 오류·타임아웃)       | 3회 재시도 후 **fail-open**(`success` 처리) + 관리자 알림. 도구 장애로 팀 작업이 멈추면 안 된다                                    |
| 문항 오류 의심                           | 응시 화면에서 즉시 이의제기 → 해당 문항 채점 제외 후 재계산, 관리자 큐로 이동                                                      |
| 긴급 배포(hotfix)                        | `[skip-quiz]` 라벨 부착 시 면제, 단 audit log 기록 및 리포트 노출                                                                  |

---

## 4. 시스템 아키텍처

### 4.1 컨테이너 구성 (docker-compose)

```
                    ┌──────────────────────────┐
   GitHub ─webhook─▶ │        nginx             │
   Browser ────────▶ │  :443 TLS 종료           │
                    │  / → 정적 파일(Vite 빌드) │
                    │  /api → api               │
                    └────────┬─────────────────┘
                             │
                    ┌────────▼─────────┐
                    │  api             │  FastAPI + Uvicorn
                    │  - OAuth 로그인   │  (Gunicorn 워커 관리)
                    │  - 웹훅 수신      │
                    │  - 퀴즈 조회/채점  │
                    └──┬────────────┬──┘
                       │            │
              ┌────────▼───┐   ┌────▼────────────┐
              │  redis     │   │  mysql.         │
              │  큐 + 캐시  │   │  영속 데이터       │
              └────────┬───┘   └─────────────────┘
                       │
              ┌────────▼────────────────────────┐
              │  worker                         │  Celery
              │  - diff 수집/필터링                │
              │  - LangChain 퀴즈 생성 (LCEL)     │
              │  - GitHub 상태 갱신               │
              └────────┬────────────────────────┘
                       │
                  ┌────▼─────────────┐
                  │  beat (스케줄러)   │  쿨다운 해제, 통계 집계,
                  └──────────────────┘  stale PR 정리
```

### 4.2 웹훅을 반드시 비동기 처리해야 하는 이유

GitHub은 웹훅 응답을 **10초 이내**에 기대한다. LLM 퀴즈 생성은 20~60초가 소요되므로 동기 처리가 불가능하다.

```python
@router.post("/webhooks/github")
async def github_webhook(request: Request, x_hub_signature_256: str = Header(...)):
    raw = await request.body()
    verify_signature(raw, x_hub_signature_256)   # HMAC-SHA256, 실패 시 401
    event = json.loads(raw)

    delivery_id = request.headers["X-GitHub-Delivery"]
    if await is_duplicate(delivery_id):          # 멱등성 보장 (GitHub은 재전송한다)
        return {"status": "duplicate"}

    generate_quiz.delay(event)                    # Celery 큐로 넘기고 즉시 반환
    return {"status": "accepted"}                 # 200, 100ms 이내
```

---

## 5. 기술 스택 상세

### 5.1 백엔드 (Python)

| 영역          | 선택                                         | 비고                                                                                                    |
| ------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 웹 프레임워크 | **FastAPI**                                  | 비동기 네이티브, Pydantic 기반 자동 검증/문서화                                                         |
| ASGI 서버     | Uvicorn (+ Gunicorn 워커 매니저)             |                                                                                                         |
| ORM           | **SQLAlchemy 2.0 (async)** + Alembic         | 마이그레이션 필수                                                                                       |
| DB 드라이버   | `asyncmy` 또는 `aiomysql`                    |                                                                                                         |
| 스키마/검증   | Pydantic v2                                  | LLM structured output에도 동일 모델 재사용                                                              |
| GitHub API    | **`githubkit`** (권장) 또는 PyGithub         | githubkit은 async 네이티브 + GitHub App 인증 + 타입 힌트 제공. PyGithub은 동기 기반이라 워커에서만 사용 |
| 작업 큐       | **Celery + Redis**                           | MVP 단계에서는 FastAPI `BackgroundTasks`로 시작 후 이관 가능. 경량 대안은 `arq`                         |
| LLM           | **LangChain (LCEL chain)**                   | `with_structured_output()`으로 Pydantic 모델 직접 파싱. LangGraph 미사용 사유는 §9 참조                 |
| 세션          | JWT (`pyjwt`) 또는 `itsdangerous` 서명 쿠키  | HttpOnly + Secure + SameSite=Lax                                                                        |
| 토큰 암호화   | `cryptography` Fernet                        | GitHub access token은 DB에 반드시 암호화 저장                                                           |
| 테스트        | pytest + pytest-asyncio + `respx`(HTTP 목킹) |                                                                                                         |
| 품질          | ruff + mypy                                  |                                                                                                         |

### 5.2 프론트엔드

| 영역       | 선택                                                      |
| ---------- | --------------------------------------------------------- |
| 빌드       | Vite                                                      |
| 프레임워크 | React 19 + TypeScript                                     |
| 라우팅     | React Router                                              |
| 서버 상태  | TanStack Query                                            |
| 스타일     | Tailwind CSS                                              |
| 코드 뷰어  | `shiki` 또는 `react-syntax-highlighter` (diff 하이라이팅) |

빌드 산출물은 nginx가 정적 서빙한다. SPA이므로 `try_files $uri /index.html` 설정 필요.

### 5.3 인프라

- nginx: TLS 종료(Let's Encrypt), 정적 파일 서빙, `/api` 리버스 프록시, 웹훅 엔드포인트에 rate limit
- Docker Compose로 전체 오케스트레이션 (단일 VM 배포 전제)
- 로컬 개발 시 웹훅 수신용 공개 HTTPS 터널 필요: `cloudflared tunnel` 또는 `ngrok`

---

## 6. GitHub App 명세

**OAuth App이 아니라 GitHub App을 사용한다.** 하나의 App으로 ① 사용자 로그인(user access token) ② 웹훅 수신 ③ 저장소 쓰기 작업(installation token)을 모두 처리할 수 있고, 권한이 세분화된다.

### 6.1 필요 권한

| 권한            | 수준         | 용도                                  |
| --------------- | ------------ | ------------------------------------- |
| Pull requests   | Read & Write | PR 조회, Draft 전환/승격, 코멘트 게시 |
| Contents        | Read         | diff 및 주변 파일 컨텍스트 조회       |
| Commit statuses | Read & Write | 게이트 상태 게시                      |
| Metadata        | Read         | 필수 기본 권한                        |

### 6.2 구독 웹훅 이벤트

| 이벤트 / 액션                               | 처리                                   |
| ------------------------------------------- | -------------------------------------- |
| `pull_request.opened`                       | 퀴즈 생성 시작, Draft 전환             |
| `pull_request.reopened`                     | 게이트 상태 재평가                     |
| `pull_request.synchronize`                  | 변경량 판정 후 보충 문항 여부 결정     |
| `pull_request.ready_for_review`             | 미통과 상태면 Draft로 되돌림 (설정 시) |
| `pull_request.review_requested`             | 미통과 시 안내 코멘트                  |
| `pull_request.closed`                       | 진행 중 퀴즈 정리                      |
| `installation`, `installation_repositories` | 설치/저장소 목록 동기화                |

### 6.3 인증 흐름

```
[로그인]  브라우저 → /api/auth/github/login
                  → GitHub 인가 화면 (state 파라미터로 CSRF 방어)
                  → /api/auth/github/callback
                  → user access token 획득 → Fernet 암호화 후 DB 저장
                  → 동일 토큰으로 GET /user/installations 호출 → 접근 가능한 installation 목록 확인
                  → user_installations upsert (§7, "로그인 사용자가 속한 installation"의 근거)
                  → 세션 쿠키 발급

[쓰기]    워커 → App 개인키로 JWT 생성 (유효 10분)
              → POST /app/installations/{id}/access_tokens
              → installation token (1시간) 획득, Redis에 55분 캐싱
              → Commit Status / Draft 전환 / 코멘트 실행
```

### 6.4 사전 확인 필요 사항

- 조직 소유 저장소는 **org owner의 App 설치 승인**이 필요하다. 기획 승인 단계에서 미리 확보할 것
- private 저장소 코드가 외부 LLM API로 전송된다. **회사 보안 정책 검토가 선행 조건**이며, 불가할 경우 자체 호스팅 모델(Ollama + 코드 특화 모델)로 대체 검토

---

## 7. 데이터 모델 (MySQL)

> **ENUM 값 표기 규칙:** 아래 모든 ENUM 컬럼은 Python `str` Enum의 **멤버 이름**(대문자, 예 `READY`)을 그대로 저장한다 — SQLAlchemy `Enum(PyEnum)`의 기본 동작이며, 코드에서 `values_callable`로 재정의하지 않는다. 애플리케이션 코드(API 응답 직렬화, 비교 로직, Commit Status 매핑 등)는 항상 Python Enum의 `.value`(소문자, 예 `ready`)만 사용하므로 영향이 없다. 다만 **DB를 직접 조회하는 모든 경우**(수동 검증 SQL, admin 도구, 감사 로그·통계 쿼리)는 대문자 값으로 조회해야 한다.

```sql
-- 사용자
users (
  id BIGINT PK AUTO_INCREMENT,                    -- 내부 식별자
  github_user_id BIGINT UNIQUE NOT NULL,          -- GitHub 사용자 ID (OAuth 로그인 시 매칭 키)
  github_login VARCHAR(255) NOT NULL,              -- GitHub 로그인 아이디(핸들), 변경 가능하므로 매칭 키로 쓰지 않음
  avatar_url VARCHAR(512),                        -- 프로필 이미지 URL
  access_token_encrypted VARBINARY(1024),         -- GitHub user access token, Fernet 암호화 저장
  role ENUM('member','admin') DEFAULT 'member',   -- admin이면 저장소 설정 수정·이의제기 큐 접근 가능
  created_at DATETIME, updated_at DATETIME        -- 레코드 생성/수정 시각
)

-- App 설치. 이 문서에서 "팀"은 별도 엔터티가 아니라 installations의 한 row(=조직 하나)를 뜻한다.
-- teams/team_members 테이블이나 팀 생성·가입 플로우는 없다 (§8.2, §13 참조).
installations (
  id BIGINT PK,                                       -- 내부 식별자
  github_installation_id BIGINT UNIQUE NOT NULL,      -- GitHub App 설치 ID (웹훅 payload의 installation.id)
  account_login VARCHAR(255),                         -- 설치 대상 조직/개인 계정명
  account_type VARCHAR(32),                           -- 'Organization' | 'User'
  suspended_at DATETIME NULL                          -- 설치자가 App을 일시 중단시킨 시각, NULL이면 정상
)

-- 사용자 ↔ 설치 매핑. "로그인 사용자가 속한 installation"을 결정하는 유일한 근거 (§6.3)
user_installations (
  user_id BIGINT FK, installation_id BIGINT FK,  -- 접근 가능한 사용자 / 설치(조직)
  synced_at DATETIME,                            -- 마지막으로 GET /user/installations를 반영한 시각
  PRIMARY KEY (user_id, installation_id)
)

-- 저장소 및 정책
repositories (
  id BIGINT PK,                                  -- 내부 식별자
  installation_id BIGINT FK,                     -- 소속 App 설치
  github_repo_id BIGINT UNIQUE NOT NULL,         -- GitHub 저장소 고유 ID
  full_name VARCHAR(512) NOT NULL,               -- "owner/repo" 형식
  quiz_enabled BOOLEAN DEFAULT TRUE,             -- 저장소 단위 게이트 온/오프 (장애 시 긴급 비활성화용)
  config JSON,        -- 저장소별 정책 설정, 7.1 참조
  INDEX (installation_id)
)

-- PR 및 게이트 상태
pull_requests (
  id BIGINT PK,                          -- 내부 식별자
  repository_id BIGINT FK,               -- 소속 저장소
  pr_number INT NOT NULL,                -- 저장소 내 PR 번호 (#123)
  head_sha CHAR(40) NOT NULL,            -- 게이트 대상 최신 커밋 SHA (퀴즈 캐시 키의 일부)
  author_user_id BIGINT FK NULL,         -- PR 작성자. users 미가입(로그인 전) 상태면 NULL 허용
  title VARCHAR(1024),                   -- PR 제목
  state ENUM('OPEN','CLOSED','MERGED'),  -- GitHub 상의 PR 상태. Python str Enum의 멤버 이름을 그대로 저장 (SQLAlchemy Enum 기본 동작, §7 각주 참조)
  gate_state ENUM(
    'GENERATING',    -- 퀴즈 생성 중
    'READY',         -- 생성 완료, 응시 대기
    'IN_PROGRESS',   -- 응시 진행 중
    'PASSED',        -- 통과 (Commit Status success)
    'COOLDOWN',      -- 미통과 후 재응시 대기
    'EXEMPTED',      -- 변경량 미달/제외 경로로 자동 면제
    'BYPASSED',      -- admin이 게이트 우회 (§2.3)
    'ERROR'          -- 생성 실패, 재시도 소진 후 fail-open 처리
  ),
  bypass_reason VARCHAR(255) NULL,       -- bypassed 상태일 때 사유 (audit log와 함께 기록)
  UNIQUE KEY (repository_id, pr_number),
  INDEX (gate_state)
)

-- 퀴즈 (head_sha 단위로 캐싱)
quizzes (
  id BIGINT PK,                                   -- 내부 식별자
  pull_request_id BIGINT FK,                      -- 소속 PR
  head_sha CHAR(40) NOT NULL,                     -- 생성 시점의 커밋 SHA (캐시 키)
  kind ENUM('FULL','SUPPLEMENT') DEFAULT 'FULL',  -- 최초 전체 퀴즈 / synchronize 이후 보충 문항
  status ENUM('GENERATING','READY','FAILED'),     -- 생성 파이프라인 진행 상태
  model VARCHAR(128), prompt_version VARCHAR(32), -- 사용 모델·프롬프트 버전 (비용 추적, 회귀 테스트 매칭)
  input_tokens INT, output_tokens INT, cost_usd DECIMAL(10,5), -- 호출당 비용 (§9.4 주간 리포트 집계용)
  generated_at DATETIME,                          -- 생성 완료 시각
  UNIQUE KEY (pull_request_id, head_sha, kind)    -- 동일 커밋·종류 중복 생성 방지 (캐싱)
)

-- 문항  ※ correct_answer는 절대 클라이언트로 전송하지 않는다
quiz_questions (
  id BIGINT PK,                                                -- 내부 식별자
  quiz_id BIGINT FK,                                           -- 소속 퀴즈
  seq INT,                                                     -- 문항 노출 순서
  qtype ENUM('SINGLE_CHOICE','MULTI_CHOICE','SHORT_ANSWER'),   -- 문항 유형. §9.2 구현은 single_choice(4지선다)만 생성
  body TEXT,                                                   -- 문항 본문
  choices JSON,                                                -- 선택지 배열
  correct_answer JSON,          -- 서버 전용, 정답 인덱스/값
  explanation TEXT,             -- 채점 후에만 전송, 오답 해설
  source_refs JSON,             -- [{file, start_line, end_line}] 근거 diff 위치 (이의제기 검토·코드 링크에 사용)
  difficulty TINYINT,           -- 난이도 1~3
  is_voided BOOLEAN DEFAULT FALSE, -- 이의제기 인정 등으로 채점에서 제외된 문항
  INDEX (quiz_id)
)

-- 응시
quiz_attempts (
  id BIGINT PK,                        -- 내부 식별자
  quiz_id BIGINT FK, user_id BIGINT FK, -- 대상 퀴즈 / 응시자
  started_at DATETIME,                 -- 서버 기준 응시 시작 시각 (제한시간 판정 기준, §8.1)
  submitted_at DATETIME NULL,          -- 제출 시각, NULL이면 응시 중이거나 미제출
  score DECIMAL(5,2) NULL,             -- 채점 점수(0~100), 미채점 시 NULL
  passed BOOLEAN NULL,                 -- pass_score 기준 통과 여부
  INDEX (quiz_id, user_id)
)

quiz_answers (
  id BIGINT PK,                                   -- 내부 식별자
  attempt_id BIGINT FK, question_id BIGINT FK,    -- 소속 응시 / 대상 문항
  submitted_answer JSON,                          -- 제출 답안(선택 인덱스 등)
  is_correct BOOLEAN,                             -- 서버 채점 결과
  UNIQUE KEY (attempt_id, question_id)            -- 응시당 문항별 답안 1건만 허용
)

-- 이의제기
question_disputes (
  id BIGINT PK,                                                     -- 내부 식별자
  question_id BIGINT FK, user_id BIGINT FK, attempt_id BIGINT FK,   -- 대상 문항 / 제기자 / 해당 응시 회차
  reason TEXT,                                                      -- 이의제기 사유
  status ENUM('OPEN','ACCEPTED','REJECTED') DEFAULT 'OPEN',         -- 처리 상태
  resolved_by BIGINT NULL, resolved_at DATETIME NULL                -- 처리한 admin user_id / 처리 시각
)

-- 웹훅 멱등성
webhook_deliveries (
  delivery_id CHAR(36) PK,                       -- GitHub `X-GitHub-Delivery` 헤더값 (멱등성 키)
  event_type VARCHAR(64), received_at DATETIME,  -- 이벤트명(예: pull_request) / 수신 시각
  INDEX (received_at)                -- 7일 경과분 주기 삭제
)

-- 감사 로그
audit_logs (
  id BIGINT PK,                                -- 내부 식별자
  actor_user_id BIGINT NULL, action VARCHAR(64), -- 행위 주체(시스템 자동 처리 시 NULL) / 행위 종류(예: gate_bypass, config_update)
  target_type VARCHAR(64), target_id BIGINT,   -- 대상 리소스 종류 / ID
  detail JSON, created_at DATETIME             -- 행위 상세(변경 전/후 값 등) / 기록 시각
)
```

### 7.1 저장소별 설정 스키마 (`repositories.config`)

```json
{
  "question_count": 6,
  "pass_score": 70,
  "time_limit_seconds": 900,
  "cooldown_seconds": 600,
  "min_changed_lines": 10,
  "resync_threshold_lines": 30,
  "exclude_paths": [
    "**/*.lock",
    "**/package-lock.json",
    "**/poetry.lock",
    "**/*.min.js",
    "**/migrations/**",
    "**/*_pb2.py",
    "**/dist/**",
    "**/vendor/**",
    "**/*.snap"
  ],
  "enforce_draft": true,
  "revert_review_request": false,
  "skip_labels": ["skip-quiz", "hotfix"],
  "status_context": "proof/comprehension"
}
```

---

## 8. API 명세 (요약)

| Method  | Path                            | 설명                                 |
| ------- | ------------------------------- | ------------------------------------ |
| `GET`   | `/api/auth/github/login`        | OAuth 인가 시작                      |
| `GET`   | `/api/auth/github/callback`     | 콜백, 세션 발급                      |
| `POST`  | `/api/auth/logout`              | 로그아웃                             |
| `GET`   | `/api/me`                       | 현재 사용자                          |
| `GET`   | `/api/pull-requests`            | 내 PR 목록 + 게이트 상태 (기본: 로그인 사용자가 작성한 PR로 스코프, 8.2 참조) |
| `GET`   | `/api/pull-requests/{id}`       | PR 상세                              |
| `POST`  | `/api/quizzes/{id}/attempts`    | 응시 시작 (문항 반환, **정답 제외**) |
| `POST`  | `/api/attempts/{id}/submit`     | 제출 → 서버 채점 → 결과·해설 반환    |
| `GET`   | `/api/attempts/{id}`            | 응시 결과 조회                       |
| `POST`  | `/api/questions/{id}/disputes`  | 이의제기                             |
| `GET`   | `/api/repositories`             | 연동 저장소 목록                     |
| `PATCH` | `/api/repositories/{id}/config` | 정책 수정 (admin)                    |
| `GET`   | `/api/stats/team`               | 팀 통계 (로그인 사용자가 속한 installation 단위로 스코프, 8.2 참조) |
| `GET`   | `/api/disputes`                 | 이의제기 큐 (admin 권한으로 전체 조회, 8.2 참조) |
| `POST`  | `/api/webhooks/github`          | GitHub 웹훅 수신                     |

### 8.1 보안 원칙

1. **정답은 어떤 응답에도 포함하지 않는다.** 채점은 100% 서버에서만 수행한다. 프론트엔드 DevTools로 정답이 노출되면 도구 자체가 무의미해진다
2. 해설(`explanation`)은 채점 완료 후에만 전송한다
3. 응시 시작 시 서버가 `started_at`을 기록하고, 제한 시간 초과 판정도 서버 시각 기준으로 한다
4. **본인의 PR에 대한 퀴즈만 응시 가능**하도록 인가 검사 (PR author == 로그인 사용자)

### 8.2 엔드포인트 패턴 검토

**`/api/me` — 유지한다.** "명사·복수형 리소스"라는 REST 원칙에서는 벗어나지만, 현재 로그인한 사용자를 가리키는 이 별칭은 이 서비스가 이미 의존하는 GitHub API 자체의 관례(`GET /user`)이기도 하다. 클라이언트가 자신의 `user_id`를 알아야 `/api/users/{id}`를 호출할 수 있는 구조보다, 세션만으로 접근 가능한 `/api/me`가 실용적이다. `/api/me/pull-requests`와의 일관성도 유지된다. 그대로 둔다.

**`/api/admin/disputes` → `/api/disputes`로 변경한다.** 권한 수준(`admin`)을 URL 경로에 하드코딩하지 않는다는 원칙에 따른 것이다. 리소스명은 이미 `POST /api/questions/{id}/disputes`에서 쓰고 있는 "disputes"와 통일하고, 누가 접근 가능한지는 경로가 아니라 인가 계층(FastAPI `Depends(require_admin)`)에서 결정한다.

- v1: `GET /api/disputes`는 admin 권한 의존성을 요구하고 전체 큐를 반환한다 (동작은 기존과 동일, 경로만 변경)
- 추후 "내가 제기한 이의 목록"이 필요해지면 `?mine=true` 쿼리 파라미터나 `/api/me/disputes`로 확장한다 — 권한별로 새 경로를 만드는 대신 같은 리소스를 재사용한다
- `PATCH /api/repositories/{id}/config`의 `(admin)` 표기는 하위 리소스(`/repositories/{id}/...`)라 경로 자체에 문제가 없으므로 변경하지 않는다. 권한 검사는 동일하게 의존성 레이어에서 수행한다

**`/api/me/pull-requests` → `/api/pull-requests`로 변경한다.** 같은 이유다. 이 문서에는 이미 단일 PR 조회가 `/api/pull-requests/{id}`로 최상위 경로에 있는데, 목록만 `/api/me/` 하위에 두면 같은 리소스가 컬렉션과 아이템에서 서로 다른 루트를 갖게 된다. `/api/pull-requests`로 통일하고, "누구 PR을 보여줄지"는 기본값(로그인 사용자가 작성한 PR)을 세션에서 결정한다. 팀/admin이 다른 사람 PR도 봐야 하는 요구가 생기면 `?author=` 같은 쿼리 파라미터로 확장하고, 새 경로를 만들지 않는다.

**`GET /api/stats/team`의 "팀"은 실제로는 installation(조직)이다.** 문서 전체에 `teams` 테이블이나 팀 생성·가입 플로우가 없다 — 로그인 사용자가 속한 GitHub App installation(§7의 `installations`, 조직 하나) 단위로 `installations → repositories → pull_requests → quiz_attempts` 체인을 따라 이미 집계가 가능하므로 별도 스키마가 필요 없다. "로그인 사용자가 속한 installation"은 자동으로 알 수 있는 게 아니라, 로그인 시 `GET /user/installations`로 동기화해 `user_installations`(§7)에 저장해둔 매핑을 조회한 것이다 — 이 테이블이 없으면 users와 installations를 이을 방법이 없다. 사용자가 여러 조직(installation)에 속하면 기본은 전체 반환, 특정 조직만 보려면 `?installation_id=`로 좁힌다. 조직 내부를 백엔드/프론트팀처럼 더 세분화한 하위 팀 통계가 실제로 필요해지면 그때 `teams`/`team_members` 테이블과 GitHub Teams 동기화를 추가한다 (§13) — 지금은 만들지 않는다.

---

## 9. 퀴즈 생성 파이프라인 (LangChain, LCEL chain)

**구현 방식 결정: LangGraph가 아니라 LangChain LCEL chain을 사용한다.** §9.1의 흐름(생성 → 자동 검증 → 실패 문항만 최대 2회 재생성)은 여러 노드가 조건에 따라 분기하는 상태 기계가 아니라, "성공할 때까지 유한 횟수만큼 반복하는 선형 루프"다. 필요한 상태는 "지금까지 만든 유효 문항 목록"과 "남은 재시도 횟수"뿐이며, 이는 일반 Python 함수의 지역 변수로 충분하다. LangGraph는 노드 간 분기·사이클·체크포인팅이 실제로 필요할 때(예: 문항 카테고리별 전용 서브체인, 조건별 재라우팅) 정당화되는데, 현재 요구사항에는 그 복잡도가 없다.

- `prompt | llm.with_structured_output(QuizDraft)` 단일 LCEL chain으로 생성한다 (§9.2)
- 검증·재생성 루프는 그래프가 아니라 이 chain을 감싸는 일반 `async` 함수(`while` 루프, 최대 2회)로 구현한다
- §13의 v2 "리뷰어 대상 퀴즈"처럼 여러 생성기가 조건에 따라 분기해야 하는 요구가 생기면 그 시점에 LangGraph로 전환한다. 지금 미리 그래프 구조를 만들 필요는 없다 (YAGNI)

### 9.1 단계

```
① diff 수집
   GET /repos/{o}/{r}/pulls/{n}/files  (페이지네이션, 파일당 patch 포함)
   ※ 파일 3000개 초과 시 diff URL 직접 다운로드로 폴백

② 필터링  ← 품질의 절반이 여기서 결정된다
   - exclude_paths 패턴 제외
   - 바이너리 / 자동생성 / vendored 제외
   - 순수 포맷팅 변경(공백·import 정렬만) 제외
   - 순수 삭제 파일 제외

③ 중요도 정렬 및 선별
   점수 = 변경라인수 × 확장자가중치 × (제어흐름 변경 여부 보정)
   상위 N개 hunk만 사용, 총 입력 토큰 상한 준수 (예: 40k)
   주변 컨텍스트 필요 시 해당 파일 원본 일부 추가 조회

④ 퀴즈 생성 — LangChain structured output (LCEL chain)
   문항 유형 배분: 영향범위 2 · 엣지케이스 2 · 설계의도 1 · 데이터흐름 1

⑤ 검증 (자동)
   - Pydantic 스키마 통과 여부
   - 정답 인덱스 범위 / 선택지 중복 / 정답 편향(항상 A 등)
   - source_refs가 실제 변경 파일을 가리키는지
   - 2차 self-check 프롬프트로 "diff만 보고 답할 수 있는가" 검증
   실패 문항은 폐기, 부족분은 재생성(최대 2회)

⑥ 저장 및 상태 갱신
   quizzes/quiz_questions INSERT → Commit Status pending("응시 필요")
   → PR 코멘트에 응시 링크 게시
```

### 9.2 구조화 출력 구현

```python
from pydantic import BaseModel, Field
from typing import Literal

class SourceRef(BaseModel):
    file: str
    start_line: int
    end_line: int

class Question(BaseModel):
    category: Literal["impact", "edge_case", "design_intent", "data_flow"]
    body: str = Field(description="한국어 질문 본문")
    choices: list[str] = Field(min_length=4, max_length=4)
    correct_index: int = Field(ge=0, le=3)
    explanation: str
    source_refs: list[SourceRef]
    difficulty: Literal[1, 2, 3]

class QuizDraft(BaseModel):
    questions: list[Question]

chain = prompt | llm.with_structured_output(QuizDraft)
draft = await chain.ainvoke({"diff": filtered_diff, "count": 6})
```

### 9.3 문항 설계 방침

검증력이 높은 유형과 낮은 유형이 명확히 갈린다.

**지향 (변경사항을 실제로 읽어야 답할 수 있음)**

- _영향 범위_: "이 함수 시그니처 변경으로 수정이 필요한 다른 호출부는?"
- _엣지 케이스_: "입력이 빈 리스트일 때 이 로직은 어떻게 동작하는가?"
- _데이터 흐름_: "이 값은 어디서 주입되어 최종적으로 어디에 저장되는가?"
- _설계 의도_: "이 변경에서 트랜잭션 경계를 여기로 잡은 이유는?"

**회피 (기억력·일반지식 테스트가 됨)**

- "변경된 함수의 이름은?" (단순 암기)
- "Python의 `dict.get()`은 무엇을 반환하는가?" (diff와 무관한 일반지식)
- diff를 보지 않고도 상식으로 맞출 수 있는 문항

### 9.4 비용 관리

- 퀴즈는 `(pull_request_id, head_sha)` 단위로 캐싱 → 재응시 시 재생성 없음
- 입력 토큰 상한 적용, 대형 PR은 선별된 hunk만 사용
- 모델 티어 분리: 소규모 PR은 경량 모델, 200줄 초과 시 상위 모델
- `quizzes` 테이블에 토큰·비용 기록 → 주간 비용 리포트
- 예상 규모: PR당 입력 10~30k 토큰. 팀 10명, 주 40 PR 기준 월 비용은 통제 가능한 수준

---

## 10. 화면 구성

| 화면                  | 주요 요소                                                                          |
| --------------------- | ---------------------------------------------------------------------------------- |
| 로그인                | GitHub 로그인 버튼 단일                                                            |
| 대시보드              | 내 PR 목록, 게이트 상태 배지, 응시 필요 항목 상단 고정                             |
| 퀴즈 응시             | 좌측 diff 뷰어(구문 강조) / 우측 문항. 상단 진행률·남은 시간, 문항별 이의제기 버튼 |
| 결과                  | 점수, 문항별 정오답, 해설, 관련 코드 위치 링크, 재응시 버튼(쿨다운 카운트다운)     |
| 팀 통계               | 저장소별·기간별 통과율, 카테고리별 취약 영역, 개인별 추이                          |
| 저장소 설정 (admin)   | 정책 편집 폼, 제외 경로 관리, 미리보기                                             |
| 이의제기 관리 (admin) | 대기 큐, 인정/반려, 프롬프트 개선 메모                                             |

> **UX 원칙:** diff와 문항이 항상 같은 화면에 있어야 한다. 코드를 보러 GitHub으로 왕복하게 만들면 응시율이 떨어진다.

---

## 11. 개발 마일스톤 (5주)

| 주차    | 산출물                           | 완료 기준                                                                                                                |
| ------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **1주** | 기반 구축                        | docker-compose 기동, GitHub App 등록, OAuth 로그인 성공, 내 PR 목록 조회                                                 |
| **2주** | **게이트 파이프라인 (LLM 없음)** | 웹훅 수신 → 서명 검증 → 고정된 더미 문항 3개 → 통과 시 Commit Status `success` → 실제 저장소에서 머지 차단·해제 E2E 검증 |
| **3주** | 퀴즈 생성                        | diff 수집·필터링, LangChain 생성, 자동 검증, Celery 비동기화, 서버 채점                                                  |
| **4주** | 완성도                           | Draft 전환/승격, `synchronize` 정책, 이의제기, 쿨다운, 응시 UI 고도화                                                    |
| **5주** | 운영 준비                        | 팀 통계, 저장소 설정 화면, admin 큐, 로깅·모니터링, 내부 파일럿 시작                                                     |

### 핵심 조언: LLM을 가장 마지막에 붙인다

2주차에 **더미 문항으로 게이트 파이프라인을 먼저 완성**해야 한다. 웹훅 → 상태 게시 → 머지 차단/해제라는 뼈대가 확실히 돌아가는 것이 프로젝트의 성립 조건이고, 퀴즈 품질 튜닝은 그 위에서 무한히 반복할 작업이기 때문이다. 순서를 반대로 하면 프롬프트만 만지다가 정작 게이트가 동작하지 않는 상태로 시간을 소진한다.

---

## 12. 리스크 및 대응

| #   | 리스크                                    | 영향                     | 대응                                                                                                       |
| --- | ----------------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------- |
| R1  | **문항 품질 미달** (프로젝트 최대 리스크) | 팀 신뢰 상실, 도구 폐기  | 이의제기 필수 제공, 인정률 지표 추적, 프롬프트 버저닝 + 회귀 테스트셋(실제 PR 30건 고정) 구축              |
| R2  | LLM 생성 정답 오류                        | 통과 못 하는 억울한 상황 | 이의제기 시 즉시 해당 문항 채점 제외 후 재계산 (관리자 승인 대기 없이 선반영)                              |
| R3  | 개발 속도 저하 반발                       | 도입 실패                | 최소 변경량 면제 기준, hotfix 라벨, 목표 응시 시간 8분 이내, 파일럿 팀 먼저                                |
| R4  | private 코드의 외부 LLM 전송              | 보안 정책 위반           | **기획 승인 전 보안 검토 필수**. 불가 시 Ollama 자체 호스팅 검토, secret 패턴 마스킹                       |
| R5  | 대형 PR 토큰 초과                         | 생성 실패                | hunk 선별 + 토큰 상한. 500줄 초과 PR은 "PR 분할 권장" 안내 후 면제 처리                                    |
| R6  | 퀴즈 생성 장애로 작업 중단                | 전사 개발 블로킹         | **fail-open 원칙.** 3회 재시도 후 `success` 처리 + 관리자 알림. 도구가 파이프라인을 막아선 안 된다         |
| R7  | 작성자가 LLM으로 답 도출                  | 검증력 저하              | 원리적 차단 불가. "설계 의도" 유형 비중 확대, 규율 도구로 포지셔닝, 통과율만으로 인사 평가하지 않음을 명시 |
| R8  | 웹훅 중복·누락                            | 상태 불일치              | `X-GitHub-Delivery` 멱등성 처리 + beat 스케줄러가 15분 주기로 open PR 상태 리컨실                          |
| R9  | admin 게이트 우회 남용                    | 규율 무력화              | audit log 기록 + 주간 리포트 노출 (차단이 아니라 가시화로 대응)                                            |

---

## 13. 향후 확장 (v2 이후)

- **리뷰어 대상 퀴즈**: 승인 전 리뷰어의 이해도도 검증 (형식적 승인 방지). 유사 서비스들이 실제로 이 방향을 취하고 있다
- 취약 영역 기반 개인 학습 추천
- Slack 연동 (응시 알림, 주간 리포트)
- GitLab / Bitbucket 지원
- CI에서 실행 가능한 CLI 클라이언트
- 자체 호스팅 모델 옵션 (보안 요구가 강한 조직 대응)
- **조직 내부 하위 팀 통계**: GitHub Teams 동기화(`teams`/`team_members` 테이블 추가, App `Members: Read` 권한 필요)로 백엔드/프론트팀처럼 organization 하위 단위 통계 제공. v1은 installation(조직) 단위로 충분하다고 보고 제외 (§8.2)

---

## 부록 A. 초기 결정 사항 체크리스트

기획 승인 전 확정이 필요한 항목:

- [ ] 조직 owner의 GitHub App 설치 승인 가능 여부
- [ ] private 코드의 외부 LLM API 전송에 대한 보안 정책 판단
- [ ] 사용할 LLM 제공자 및 월 예산 상한
- [ ] 파일럿 대상 저장소 1~2개 선정
- [ ] Ruleset 필수 체크 등록 권한 보유자 확인
- [ ] 통과율을 인사 평가에 사용하지 않는다는 원칙의 명시적 합의


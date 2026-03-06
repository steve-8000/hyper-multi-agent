# Hyper Multi-Agent — Claude Code Plugin

Claude Code를 **컨트롤타워**로 활용하여 여러 AI 모델에 작업을 **무제한 병렬 분배**하는 올인원 플러그인입니다.
`./install.sh` 하나로 프록시 서버, MCP 브릿지, Claude Code 플러그인까지 모든 환경을 자동 구성합니다.

## Quick Install

### Server (프록시를 호스팅하는 머신)

```bash
git clone https://github.com/steve-8000/hyper-multi-agent.git
cd hyper-multi-agent
./install.sh --server
```

설치 후 프록시 시작:
```bash
~/.hyper-multi-agent/start-proxy.sh start
```

설치가 끝나면 팀원에게 공유할 정보가 출력됩니다:
```
  Proxy URL: http://<your-ip>:8317
  API Key:   hyper-xxxxxxxx...
```

### Client (팀원 / 원격 접속자)

```bash
git clone https://github.com/steve-8000/hyper-multi-agent.git
cd hyper-multi-agent
./install.sh --client
```

서버 관리자에게 받은 **Proxy URL**과 **API Key**만 입력하면 끝입니다.
`hyper-mcp` 바이너리 하나만 다운로드되고, 프록시 서버는 설치하지 않습니다.

> IP 주소와 API 키는 로컬(`~/.hyper-multi-agent/state.env`)에만 저장되며, 레포에는 절대 포함되지 않습니다.

## Architecture

```
User: "REST API with auth 만들어줘"
         │
    Claude (Control Tower)
    ├── 1. Plan: 작업 분석 및 설계
    ├── 2. Decompose: 독립 서브태스크로 분해
    │
    ├──→ Hyper-AI(High): "Auth + JWT + 보안 미들웨어"       ──┐
    ├──→ Hyper-AI(High): "핵심 비즈니스 로직 + 검증"       ──┤
    ├──→ Hyper-AI(Mid):  "API 라우트 핸들러 + CRUD"        ──┤  ALL PARALLEL
    ├──→ Hyper-AI(Mid):  "DB 서비스 레이어"                ──┤
    ├──→ Hyper-AI(Low):  "Express 앱 설정 + config"        ──┤
    ├──→ Hyper-AI(Low):  "TypeScript 타입 정의"            ──┤
    └──→ Hyper-AI(Low):  "에러 처리 유틸 + DB 스키마"      ──┘
                                                              │
    ├── 3. Integrate: 결과 수집, 검수, 조립                ◄──┘
    ├── 4. Write: 파일 생성
    ▼
    Done
```

### 3-Tier 모델 역할 분담

| Tier | Name | Model | Alias | 용도 |
|------|------|-------|-------|------|
| - | **Control Tower** | Claude (현재 세션) | - | 계획, 분해, 분배, 통합 |
| High | **Hyper-AI(High)** | GPT-5.3-Codex | `coder-best` | 복잡한 알고리즘, 핵심 로직, 보안 코드 |
| Mid | **Hyper-AI(Mid)** | GPT-5.3-Codex-Spark | `coder-fast` | 표준 패턴, API 엔드포인트, 컴포넌트 로직 |
| Low | **Hyper-AI(Low)** | Qwen 3.5:35b (local) | `local-cheap` | 보일러플레이트, 설정, 타입, 유틸 |
| Review | **Review-Deep** | Claude Opus (via proxy) | `review-deep` | 아키텍처 리뷰, 설계 검증 |

### 핵심 규칙
- 같은 작업을 여러 모델에 중복 시키지 않음
- 독립적인 작업은 전부 동시 병렬 호출 (3개 티어에 분산)
- Claude는 코드를 직접 작성하지 않고 모델에 위임
- 복잡도에 따라 High/Mid/Low 적절히 배분

## What `install.sh` Does

### Server mode (`--server`)

| 단계 | 내용 |
|------|------|
| Mode | 서버/클라이언트 선택 |
| Preflight | python3, curl 확인, 플랫폼 감지 |
| Config | Ollama URL, API Key 입력 (자동 생성 가능) |
| Binaries | hyper-mcp + hyper-ai-proxy + cli-proxy-api-plus 설치 |
| Proxy | start-proxy.sh 생성 (start/stop/restart/status) |
| Plugin | Claude Code 플러그인 + mcp.json + 권한 설정 |
| Verify | 바이너리, 플러그인, 프록시 연결 확인 |

### Client mode (`--client`)

| 단계 | 내용 |
|------|------|
| Config | Proxy URL + API Key 입력 (서버 관리자에게 받은 값) |
| Binary | **hyper-mcp만** 다운로드 (프록시 바이너리 불필요) |
| Plugin | Claude Code 플러그인 + mcp.json + 권한 설정 |
| Verify | hyper-mcp, 플러그인, 프록시 연결 확인 |

## Commands

| Command | Description |
|---------|-------------|
| `/hyper-dev <task>` | 작업 분해 → 무제한 병렬 MCP 호출 → 결과 통합 |
| `/hyper-review <file>` | review-deep 모델로 아키텍처 리뷰 |

`multi-agent-dispatch` 스킬이 모든 코딩 작업에서 자동 활성화되어, 명시적 커맨드 없이도 멀티에이전트 패턴이 적용됩니다.

## Proxy Management

```bash
# 시작
~/.hyper-multi-agent/start-proxy.sh start

# 상태 확인
~/.hyper-multi-agent/start-proxy.sh status

# 중지
~/.hyper-multi-agent/start-proxy.sh stop

# 재시작
~/.hyper-multi-agent/start-proxy.sh restart
```

## Reconfigure / Uninstall

```bash
# IP, API Key 변경
./install.sh --reconfigure

# 완전 제거
./install.sh --uninstall
```

## Prerequisites

- **Claude Code CLI** (최신 버전)
- **python3** (JSON 설정 파일 처리)
- **curl** (바이너리 다운로드)
- **Ollama** (선택 — 로컬 `coder-fast` 사용 시)

## Plugin Structure

```
hyper-multi-agent/
├── .claude-plugin/plugin.json    # 플러그인 메타데이터
├── commands/
│   ├── hyper-dev.md              # /hyper-dev 커맨드
│   └── hyper-review.md           # /hyper-review 커맨드
├── skills/
│   └── multi-agent-dispatch/
│       └── SKILL.md              # 자동 활성화 스킬
├── proxy/
│   └── config.yaml.template      # 프록시 설정 템플릿
├── install.sh                    # 원클릭 설치
├── README.md
└── LICENSE
```

## License

MIT

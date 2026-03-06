# Hyper Multi-Agent — Claude Code Plugin

Claude Code를 **컨트롤타워**로 활용하여 여러 AI 모델에 작업을 **무제한 병렬 분배**하는 올인원 플러그인입니다.

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

## System Overview

```
┌─────────────────────────────────────────────────┐
│  HyperAI App (macOS 메뉴바 앱)                    │
│  ├── cli-proxy-api-plus (8318) — OAuth, 모델 라우팅 │
│  ├── hyper-ai-proxy (8317) — 외부접속, API Key 인증  │
│  └── Settings UI — 프로바이더, 외부접속, Ollama 설정   │
└────────────────────┬────────────────────────────┘
                     │ port 8317
        ┌────────────┴────────────┐
        │                         │
   Local (Server)            Remote (Client)
   hyper-mcp ──→ 127.0.0.1   hyper-mcp ──→ IP:8317
        │                         │ + API Key
   Claude Code                Claude Code
```

### 3-Tier 모델 역할 분담

| Tier | Name | Model | Alias | 용도 |
|------|------|-------|-------|------|
| - | **Control Tower** | Claude (현재 세션) | - | 계획, 분해, 분배, 통합 |
| High | **Hyper-AI(High)** | GPT-5.3-Codex | `coder-best` | 복잡한 알고리즘, 핵심 로직, 보안 코드 |
| Mid | **Hyper-AI(Mid)** | GPT-5.3-Codex-Spark | `coder-fast` | 표준 패턴, API 엔드포인트, 컴포넌트 |
| Low | **Hyper-AI(Low)** | Qwen 3.5:35b (local) | `local-cheap` | 보일러플레이트, 설정, 타입, 유틸 |
| Review | **Review-Deep** | Claude Opus (via proxy) | `review-deep` | 아키텍처 리뷰, 설계 검증 |

## Quick Start

### Server (프록시 호스팅 머신)

1. **HyperAI 앱 실행** → Settings에서:
   - External Access: ON
   - API Key 설정
   - Start 클릭

2. **Claude Code 플러그인 설치:**
```bash
git clone https://github.com/steve-8000/hyper-multi-agent.git
cd hyper-multi-agent
./install.sh --server
```

3. 팀원에게 공유:
   - Proxy URL: `http://<your-ip>:8317`
   - API Key: (앱 설정에서 확인)

### Client (팀원 / 원격 접속자)

```bash
git clone https://github.com/steve-8000/hyper-multi-agent.git
cd hyper-multi-agent
./install.sh --client
```

서버 관리자에게 받은 **Proxy URL**과 **API Key**만 입력하면 끝.

## Commands

| Command | Description |
|---------|-------------|
| `/hyper-dev <task>` | 작업 분해 → 무제한 병렬 MCP 호출 → 결과 통합 |
| `/hyper-review <file>` | review-deep 모델로 아키텍처 리뷰 |

`multi-agent-dispatch` 스킬이 모든 코딩 작업에서 자동 활성화됩니다.

## Building from Source

```bash
cd app

# Go 바이너리만 빌드
./build.sh go

# 전체 (Go + Swift app)
./build.sh app

# 크로스 컴파일 + 앱 패키징
./build.sh all
```

## Project Structure

```
hyper-multi-agent/
├── app/                          # HyperAI 앱 소스
│   ├── Package.swift             # Swift 패키지
│   ├── Sources/                  # Swift 메뉴바 앱
│   │   ├── AppDelegate.swift
│   │   ├── GoProxyManager.swift  # hyper-ai-proxy 프로세스 관리
│   │   ├── ServerManager.swift   # cli-proxy-api-plus 프로세스 관리
│   │   ├── SettingsView.swift    # SwiftUI 설정 UI
│   │   └── Resources/           # 번들 리소스 (아이콘, config, 바이너리)
│   ├── go-proxy/                # Go 소스
│   │   ├── cmd/
│   │   │   ├── hyper-ai-proxy/  # 리버스 프록시 + 인증
│   │   │   └── hyper-mcp/       # MCP stdio 브릿지
│   │   └── internal/
│   │       ├── proxy/           # HTTP 프록시, 라우팅, 사용량 추적
│   │       ├── mcp/             # MCP JSON-RPC 서버
│   │       └── ollama/          # Ollama 클라이언트
│   └── build.sh                 # 빌드 스크립트
├── .claude-plugin/              # Claude Code 플러그인 메타데이터
├── commands/                    # /hyper-dev, /hyper-review
├── skills/                      # multi-agent-dispatch 자동 스킬
├── install.sh                   # Claude Code 플러그인 설치
└── README.md
```

## Reconfigure / Uninstall

```bash
./install.sh --reconfigure   # 접속 설정 변경
./install.sh --uninstall     # 완전 제거
```

## Prerequisites

- **Claude Code CLI** (최신 버전)
- **python3** + **curl**
- **HyperAI App** (서버 모드) 또는 서버 접속 정보 (클라이언트 모드)

## License

MIT

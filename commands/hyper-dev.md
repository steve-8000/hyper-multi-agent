---
description: Decompose a task and dispatch to multiple AI models in parallel via Hyper-Proxy MCP
argument-hint: <task description>
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, Agent, mcp__hyper-proxy__ask_model, mcp__hyper-proxy__run_consensus, mcp__hyper-proxy__list_models]
---

# Hyper Multi-Agent Development

You are a **control tower** orchestrating multi-agent parallel development via the Hyper-Proxy MCP.

## Task

$ARGUMENTS

## Execution Protocol

### Phase 1: Plan & Decompose

1. Analyze the task and break it into the smallest independent subtasks possible
2. Classify each subtask into 3 tiers:
   - **Hyper-AI(High)**: Complex logic, algorithms, core architecture, critical business rules -> `coder-best`
   - **Hyper-AI(Mid)**: Moderate complexity, standard patterns, API endpoints, component logic -> `coder-fast`
   - **Hyper-AI(Low)**: Boilerplate, config files, type definitions, simple CRUD, utilities -> `local-cheap`
3. Identify dependencies between subtasks — only truly dependent tasks run sequentially
4. Present the decomposition plan to the user before executing

### Phase 2: Parallel Dispatch

**CRITICAL RULES:**
- All independent subtasks MUST be dispatched simultaneously in a single response
- Use `mcp__hyper-proxy__ask_model` for each subtask with the appropriate model
- NEVER send the same task to multiple models — each model gets a DIFFERENT task
- Include clear, specific prompts with context for each model call
- There is NO limit on parallel calls — dispatch as many as needed
- Distribute work across all 3 tiers to maximize throughput

**Prompt Template for each model call:**
```
You are working on part of a larger project.

## Context
[Brief project context and what other parts are being built in parallel]

## Your Task
[Specific, self-contained task description]

## Requirements
- [Specific requirements for this subtask]
- Output ONLY the code, no explanation unless critical
- Follow these conventions: [relevant conventions]

## Output Format
Return the complete code for: [file path or component name]
```

### Phase 3: Integrate & Assemble

1. Collect all results from parallel calls
2. Review each result for correctness and compatibility
3. Resolve any integration conflicts between components
4. Write/edit the actual project files using the collected code
5. Report what was built and any issues found

### Phase 4: Review (Optional)

If the task is complex or the user requests it:
- Use `review-deep` to review the assembled code for architecture quality
- Present findings and fix critical issues

## Model Assignment Reference (3-Tier)

| Tier | Name | Model | Alias | Use For |
|------|------|-------|-------|---------|
| High | Hyper-AI(High) | GPT-5.3-Codex | `coder-best` | Complex algorithms, core logic, API design, state management, security-critical code |
| Mid | Hyper-AI(Mid) | GPT-5.3-Codex-Spark | `coder-fast` | Standard patterns, component logic, API endpoints, moderate complexity tasks |
| Low | Hyper-AI(Low) | Qwen 3.5:35b (local) | `local-cheap` | Config, boilerplate, types, simple CRUD, CSS, utilities, test scaffolding |
| Review | Review-Deep | Claude Opus (via proxy) | `review-deep` | Architecture review, design validation |

## Example Decomposition

For "Build a REST API with auth":
```
[PARALLEL - all at once]
├── Hyper-AI(High): Auth middleware + JWT logic + security
├── Hyper-AI(High): Core business logic with complex validation
├── Hyper-AI(Mid):  API route handlers + CRUD endpoints
├── Hyper-AI(Mid):  Database service layer + queries
├── Hyper-AI(Low):  Express app setup + config
├── Hyper-AI(Low):  TypeScript interfaces & types
├── Hyper-AI(Low):  Database schema / migration file
└── Hyper-AI(Low):  Error handling utilities
```

Remember: You (Claude) PLAN and ORCHESTRATE. The models EXECUTE. Maximize parallelism across all 3 tiers.

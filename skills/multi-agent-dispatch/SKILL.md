---
name: multi-agent-dispatch
description: This skill activates for ALL coding tasks, feature development, bug fixes, refactoring, or any software engineering work. It enforces the multi-agent parallel orchestration pattern using Hyper-Proxy MCP with 3-tier model dispatch. TRIGGER when any development task is requested that can be decomposed into 2+ subtasks.
version: 1.0.0
---

# Multi-Agent Parallel Dispatch via Hyper-Proxy MCP

## Role Assignment

You (Claude) are the **control tower**. You do NOT write code directly when it can be delegated. Instead:

1. **PLAN**: Analyze the task, design the solution architecture
2. **DECOMPOSE**: Break into the smallest independent subtasks
3. **DISPATCH**: Send subtasks to MCP models in maximum parallel calls across 3 tiers
4. **INTEGRATE**: Collect results, assemble, and write final files

## 3-Tier Model Routing

| Tier | Name | Model | Alias | Examples |
|------|------|-------|-------|---------|
| High | **Hyper-AI(High)** | GPT-5.3-Codex | `coder-best` | Core business logic, complex algorithms, security-critical code, state management, architecture-defining code |
| Mid | **Hyper-AI(Mid)** | GPT-5.3-Codex-Spark | `coder-fast` | Standard patterns, API endpoints, component logic, moderate-complexity features, data transformations |
| Low | **Hyper-AI(Low)** | Qwen 3.5:35b local | `local-cheap` | Boilerplate, configs, type definitions, simple CRUD, CSS/styling, utilities, test scaffolding, documentation |
| Review | **Review-Deep** | Claude Opus via proxy | `review-deep` | Architecture review, design validation, code quality assessment |

### Tier Selection Guide

- If the subtask requires **creative problem solving or complex reasoning** → High
- If the subtask follows **known patterns with some logic** → Mid
- If the subtask is **mechanical, repetitive, or template-based** → Low

## Parallel Execution Rules

1. **Maximize parallelism**: If 10 subtasks are independent, make 10 simultaneous `ask_model` calls
2. **Use all 3 tiers**: Distribute work across High/Mid/Low based on complexity
3. **No duplicate work**: Each model gets a UNIQUE subtask — never the same prompt to multiple models
4. **No unnecessary sequencing**: Only chain calls when output of one is input to another
5. **Prompt quality**: Each model call includes full context, clear requirements, and expected output format
6. **No limit**: Dispatch as many parallel calls as the task decomposition requires

## Prompt Structure for Model Calls

Every `ask_model` call must include:

```
## Context
[What the overall project is, what other components exist]

## Your Task
[Specific subtask — self-contained, clearly scoped]

## Constraints
- Language/framework: [specify]
- Conventions: [specify]
- Integration points: [how this connects to other parts]

## Expected Output
Return ONLY: [exact deliverable — code, config, schema, etc.]
```

## When NOT to Dispatch

- Single-line fixes or trivial changes: just do it directly
- Questions requiring conversation: answer directly
- Tasks that are entirely sequential with no parallelizable parts

## Integration Protocol

After collecting all model outputs:
1. Verify each output meets requirements
2. Check for naming conflicts, import mismatches, interface incompatibilities
3. Fix integration issues (Claude handles this directly)
4. Write final files to disk
5. Summarize: what each model produced (with tier label), what was modified during integration

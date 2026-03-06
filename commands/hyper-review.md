---
description: Review code using review-deep model via Hyper-Proxy MCP
argument-hint: [file or directory to review]
allowed-tools: [Read, Glob, Grep, mcp__hyper-proxy__ask_model]
---

# Hyper Code Review

Review code using the `review-deep` model for architecture-level analysis.

## Target

$ARGUMENTS

## Process

1. Read the target files
2. Send the code to `review-deep` with the following prompt structure:

```
Review the following code for:
- Architecture quality and design patterns
- Potential bugs or logic errors
- Performance concerns
- Security vulnerabilities
- Code maintainability

Code:
[paste code here]

Provide specific, actionable feedback with file:line references.
```

3. Present the review findings organized by severity (Critical > Warning > Suggestion)
4. Ask the user which issues to fix
5. If fixing, dispatch fixes to appropriate models via parallel MCP calls

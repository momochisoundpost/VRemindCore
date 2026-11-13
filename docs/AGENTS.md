# Working with AI Agents

`VRemindCore` was built and architected from day one through human-agent collaboration. This guide documents the workflow, model stack, prompt practices, and governance patterns used to develop and maintain this repository with AI agents.

---

## 1. The Agent Stack & Philosophy

We use **Google Antigravity** paired with the **[Superpowers](https://github.com/obra/superpowers)** agentic workflow system (skills, subagents, and test-driven development gates):

```text
┌─────────────────────────────────────────────────────────────┐
│                    Human Architect / Lead                   │
│         (Sets vision, approves specs, guides review)        │
└──────────────────────────────┬──────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
┌───────────────────────────────┐   ┌───────────────────────────────┐
│       Claude 5.5 / Opus       │   │  Gemini 4 Argon / Hydrogen   │
│          Architecture         │   │    or Gemini 3.8 Flash (High) │
├───────────────────────────────┤   ├───────────────────────────────┤
│ • Architecture & System Spec  │   │ • Subagent Implementers       │
│ • Superpowers Planning Mode   │   │ • Subagent Reviewers          │
│ • Edge case discovery         │   │ • TDD Execution & Refactoring │
│ • Behavioral design docs      │   │ • Fast verification runs      │
└───────────────────────────────┘   └───────────────────────────────┘
```

### Model Role Assignment
- **Planning & Architecture (Claude 5.5 / Claude Opus):**
  - **Strengths:** High contextual rigor, structural reasoning, edge case detection, and specification design.
  - **Responsibilities:** Authoring the design spec (`specs/*.md`) and breaking down requirements into atomic, bite-sized tasks in an implementation plan (`plans/*.md`).
- **Implementation & Verification (Gemini 4 Argon / Hydrogen / Gemini 3.8 Flash):**
  - **Strengths:** High execution speed, deep code understanding, precise tool calling, fast subagent concurrency.
  - **Responsibilities:** Acting as implementer and reviewer subagents under Superpowers (Subagent-Driven Development), executing Red-Green-Refactor cycles, and running verification tests.
  - **Model Selection by Complexity:**
    - **Gemini 4 Argon / Hydrogen (Deep / High-Complexity):** Complex protocol design, async concurrency pipelines (`withTaskGroup`, cancellation handling), parser engineering (`LivePageParser`), and cross-platform networking abstraction.
    - **Gemini 3.8 Flash (High Thinking / Medium-Low Complexity):** Individual unit test authoring, fixture generation, model Codable serialization, handle normalization rules, and documentation updates.

---

## 2. Superpowers Workflow Lifecycle

Every major feature, refactor, or bugfix in `VRemindCore` follows this 5-stage lifecycle:

```text
Brainstorm / Spec ──► Implementation Plan ──► Subagent-Driven Dev ──► Portability Gate ──► Release
 (Claude Opus)          (Claude Opus)            (Gemini Stack)         (scripts/test.sh)
```

### Stage 1: Specification (`specs/*.md`)
1. Before touching code, write a design spec detailing:
   - User intent & motivation
   - Architecture & boundaries (e.g. pure `Foundation`, zero UI frameworks)
   - Canonical models & breaking change considerations
   - Concrete alternatives considered and why they were rejected
2. Get human alignment before moving to planning.

### Stage 2: Implementation Plan (`plans/*.md`)
1. Deconstruct the approved design spec into numbered, single-responsibility tasks.
2. Each task must declare:
   - Specific files touched
   - Failing test to write first (**Red**)
   - Implementation code (**Green**)
   - Verification command (e.g. `swift test --filter <SpecificSuite>`)

### Stage 3: Subagent-Driven Development (SDD)
1. For each task, launch a pair of agents:
   - **Implementer subagent:** Writes the failing test, runs it, writes the minimal code to pass, and verifies the green suite.
   - **Reviewer subagent:** Reviews code diff against the task spec, verifies portability compliance, and checks for regressions or untested edge cases.
2. Only proceed to the next task when the current task passes review.

---

## 3. Strict Rules for Coding Agents Working on `VRemindCore`

When prompting an agent to modify this codebase, feed it these non-negotiable constraints:

### Rule 1: Zero Apple Framework Pollution (The Portability Boundary)
> **Constraint:** `VRemindCore` must compile anywhere Swift runs (macOS 12+, Linux, Windows).
> - **ALLOWED:** `import Foundation`, `#if canImport(FoundationNetworking) import FoundationNetworking #endif`, `#if canImport(ObjectiveC) ... #endif`.
> - **FORBIDDEN:** Never import `AppKit`, `SwiftUI`, `Combine`, `UserNotifications`, `WidgetKit`, or `ServiceManagement`.
> - **Verification:** Always run:
>   ```bash
>   swift test --filter StreamMonitorEngineTests/testVRemindCorePortabilityZeroForbiddenImports
>   ```

### Rule 2: Strict Test-Driven Development (Red -> Green -> Refactor)
> - **Never write production code before writing a failing test.**
> - Every parser and provider must be verified against deterministic static fixtures (HTML/JSON strings or mocked responses).
> - **Never hit live external endpoints in unit tests.** Always inject a mock `HTTPFetcher`.

### Rule 3: Zero User API Keys
> - Stream providers must rely only on publicly accessible web endpoints (e.g. public `/live` HTML scraping, public unauthenticated GraphQL queries).
> - Never introduce dependencies on official developer portal API keys, OAuth consent workflows, or paid service SDKs.

### Rule 4: Stateless Engine, Event-Driven Output
> - `StreamMonitorEngine` must not mutate disk state or retain persistent state between calls.
> - Background loops emit `MonitorEvent` cases; the host application handles state persistence and OS notifications.

---

## 4. Prompt Templates for Working with Agents

### Prompt 1: Authoring a New Stream Provider (e.g., Kick or RSS)
```text
We want to add a new StreamProvider for <Platform> to VRemindCore.
Read docs/PROVIDERS.md and docs/ARCHITECTURE.md first.

Workflow requirements:
1. Follow strict TDD: create Tests/VRemindCoreTests/<Platform>StreamProviderTests.swift first with mock HTTPFetcher fixtures (live, upcoming/offline, HTTP 500 error, and invalid JSON/payload).
2. Implement Sources/VRemindCore/Providers/<Platform>StreamProvider.swift conforming to StreamProvider.
3. Keep it pure Foundation (+ FoundationNetworking). Zero Apple UI or Combine imports.
4. Add the new case to StreamPlatform and update WatchedChannel normalization.
5. Register in StreamProviderRegistry.default.
6. Verify with `swift test` and ensure testVRemindCorePortabilityZeroForbiddenImports passes.
```

### Prompt 2: Bug Investigation / Systematic Debugging
```text
A stream from <Platform> with handle <Handle> is reporting .unknown instead of .live.
Do not guess or apply speculative fixes.
1. Capture or construct a minimal raw payload reproducing the issue.
2. Write a failing test in Tests/VRemindCoreTests/<Platform>StreamProviderTests.swift reproducing the parser failure.
3. Trace the failure in the parser character-by-character or key-by-key.
4. Implement the minimal fix to restore parsing.
5. Run the full test suite to guarantee zero regressions.
```

---

## 5. Verification Checklist for Agent Handoffs

Before accepting a PR or diff generated by an AI agent:

- [ ] `swift test` (or `bash scripts/test.sh`) passes 100% of tests.
- [ ] `testVRemindCorePortabilityZeroForbiddenImports` passes.
- [ ] No network calls occur during test execution.
- [ ] New public APIs are marked `Sendable` where appropriate.
- [ ] `CHANGELOG.md` is updated following Keep a Changelog format.

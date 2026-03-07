# Root Function Definition — DrModuleV4

Status: Active  
DocVersion: v1.0.0  
LastUpdated: 2026-03-07  
Scope: Global (All Agents, All Functions)  
Authority: Canonical  

---

## Purpose

This document defines what constitutes a **Root Function** in DrModuleV4.

Root functions form the **foundational execution layer** of the system.  
They enable logging, ticketing, configuration, environment initialization, and external communication.

If root functions fail, **the system cannot operate**.

---

## Definition

A **Root Function** is a function that:

- Makes core system operation possible
- Is depended on by many other functions
- Has **no dependency on business logic**
- May be invoked **before** normal system invariants are established
- Must remain callable in **degraded or partial states**

Root functions are **not “just early functions”** — they are **structural primitives**.

---

## Characteristics of Root Functions

Root functions typically:

- Interface with external systems (APIs, transports)
- Establish identity, environment, or execution context
- Enable logging or ticket creation indirectly
- Rely on global state where necessary
- Fail fast and surface errors directly

Root functions are intentionally **minimal and opinionated**.

---

## Explicit Rule Exceptions

Root functions are **exempt** from standard DrModuleV4 function rules unless explicitly stated otherwise.

### Root Functions MAY:
- Use global variables
- Emit `Write-Error` or `Write-Warning`
- Fail without recovery
- Bypass structured logging
- Execute without prior environment initialization
- Operate without retry, rate limiting, or token refresh logic

### Root Functions MUST NOT:
- Call higher‑level business logic
- Depend on operational or workflow functions
- Implicitly assume system readiness beyond documented dependencies
- Introduce circular dependencies (especially logging or ticketing)

---

## Logging and Ticketing Constraints

Root functions may **enable** logging and ticketing, but they must not:

- Call `Add-LogEntry`
- Buffer logs
- Write ticket comments directly

Rationale:
- Root functions sit **beneath** logging and ticket workflows
- Direct logging would introduce circular initialization dependencies

---

## Dependency Direction Rule (Non‑Negotiable)

> Dependencies must always flow **downward toward root functions**.

A root function:
- May be called by any layer
- Must never call upward into Core or Operational layers

Violation of this rule constitutes a **design defect**.

---

## Classification Responsibility

A function is classified as **Root** only when:

- Explicitly designated as such
- Documented under **02 – Root Functions**
- Approved through canonical documentation

No function is implicitly root.

---

## Documentation Requirements

Every Root Function **must** have:

- A versioned `.md` contract file
- Explicit dependency listing
- Explicit non‑guarantees
- Logging/ticketing exception documentation
- Drift tracking section

Undocumented behavior **does not exist**.

---

## Examples of Root Functions

Examples (non‑exhaustive):

- API transport handlers  
- Core environment initializers  
- Logging infrastructure primitives  
- Identity and configuration loaders  

---

## Conflict Handling

If a Root Function appears to violate standard rules:

- The behavior is **documented**, not “fixed”
- Conflicts are recorded as **UNRESOLVED**
- No automatic normalization is permitted

---

## Non‑Negotiable Principle

> Root functions exist to make everything else possible — not to be convenient.

Stability, clarity, and dependency integrity take precedence over elegance.

---

## ChangeLog

- v1.0.0 — Initial V4 Root Function definition
---
name: tdd
description: "Test-driven development through agreed seams. Use when implementing a plan or fixing a bug test-first, when writing or judging tests, or when a plan must name the seams where its behaviour will be tested."
---

# Test-driven development

The red → green loop, plus what makes its tests worth keeping: where they go, what a good one is, the anti-patterns. Apply every section on every cycle, not after.

Read `GLOSSARY.md` (if present) so test names and helpers use the project's domain terms, and respect the ADRs for the area you touch.

## Seams: where tests go

A **seam** is the public interface where behaviour is observed without reaching inside: a route, a context function, a command, a message. Tests live at seams, never against internals.

- **Planning** (the human is present): the plan's **Seams** section proposes them. Ask in the interview, one seam per question, each with a one-line note on what it catches and what it misses. Recommend the smallest set that covers the critical paths and complex logic; testing every edge case is not the goal.
- **Implementing** (nobody to ask): test only at the seams PLAN.md names. A needed seam the plan lacks, or a plan with no Seams section: use the project's existing seam and test helpers (context function, route, fake), and report it as a deviation. Never ask the human about it.
- If the shape of the interface is itself in question (depth, where the seam belongs), consult `codebase-design`.

## What a good test is

It verifies behaviour through the public interface and reads like a specification ("a member can check out a valid cart"). It survives a refactor that keeps behaviour. See [tests.md](tests.md) and [mocking.md](mocking.md).

## Anti-patterns

- **Implementation-coupled**: mocks internal collaborators, tests private functions, asserts call counts, or verifies through a side channel (querying the database instead of the interface). The tell: it breaks on a refactor that keeps behaviour.
- **Tautological**: the expected value is computed the way the code computes it, so it passes by construction. Expected values come from a literal, a worked example from the plan, or the spec.
- **Horizontal slicing**: all tests first, then all code. That tests imagined behaviour. Work in **vertical slices**: one test → one implementation → next. Each test is a tracer bullet that learns from the last cycle.

## Rules of the loop

- **Red before green.** Write one failing test, see it fail for the right reason (a wrong-reason failure is a bug in the test), then write only enough code to pass it. No speculative features.
- **One slice at a time.** One seam, one test, one minimal implementation per cycle.
- **Cover the plan's examples.** Every boundary row and failure scenario in the plan becomes a test.
- **Bug found on the way**: pin it with a failing test at a seam, then fix.
- **Refactoring is not part of the loop.** It belongs to the self-review after the slices (see `code-review`), not to red → green.

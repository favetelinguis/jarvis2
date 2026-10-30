---
name: requirements-engineering
description: "Turn a loose idea or ticket into precise, testable requirements. Use when writing a plan, a refined Jira ticket, acceptance criteria, scope, or a spec, or when a request mixes the need with a proposed solution."
---

# Requirements engineering

State intent and observable behaviour, never implementation. Someone who missed the conversation must be able to implement and verify the work from your text alone (the **cold-read test**).

## Steps

1. **Need before solution.** Find the problem, who has it, what they do today, and what "better" means. Keep an insisted-on solution only as a constraint, with its reason.
2. **Probe** with the interview your role loaded (`grill-with-docs`). Branches to cover: normal, alternative and failure scenarios; nothing, one, many, the limit and one past it; duplicates; concurrency; restart midway; invalid or hostile input; missing permissions; an external system that is down or slow (load `external-integration-design` for that last one).
3. **Pin the words.** Use `GLOSSARY.md` terms exactly. Define each new domain term once, resolve synonyms to one term, check terms against the code and the glossary. New or changed terms go in the plan's Language section (load `domain-modeling`); never edit the glossary. Turn every quality word ("fast", "secure", "reliable") into a number with a unit, or drop it.
4. **Write requirements** by the rules below. Give each a stable id (R1, R2, ...). A dropped id is never reused.
5. **Add examples** where a rule branches or has a limit: concrete values and the observable result, one row per branch and boundary.
6. **Settle the seams** the tests will use (load `tdd`): one interview question per seam, then record them in the plan's Seams section.
7. **Separate design.** Questions about modules, files, types or signatures go under open questions, marked (design). Do not ask the human about them. Seams are different: they are public interfaces and the human settles them (step 6).
8. **Note decisions** that are hard to reverse, surprising and a real trade-off as ADR candidates in the plan's Decisions section.
9. **Run the cold-read test**, then confirm assumptions with the human.

## Requirement rules

- **Singular.** One behaviour; no "and/or".
- **Pattern**, with "shall" for what must happen:
  - Ubiquitous: The system shall ...
  - Event: When a trigger, the system shall ...
  - State: While a state, the system shall ...
  - Unwanted: If a condition, then the system shall ...
  - Optional: Where a feature is present, the system shall ...
- **Observable** through a public interface (screen, API, command, file, message), never internal state.
- **Precise.** Numbers with units, named actors, glossary terms only. Avoid fast, easy, robust, appropriate, as needed, support, handle, should, may, TBD, etc.
- **Failures included.** Every failure a user can observe states what they see and what state remains.
- **Verifiable.** A test can check it; if not (a latency target), say how it is verified.
- **Traceable.** It serves the stated intent; otherwise cut it.

## Where the output goes

- Plan card: [references/plan-template.md](references/plan-template.md).
- Refine card: the role defines the format; use these rules for the acceptance criteria.

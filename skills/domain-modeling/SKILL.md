---
name: domain-modeling
description: "Build and sharpen the project's domain model in GLOSSARY.md and ADRs. Use when a card introduces, renames or disputes a domain term, when a plan or review touches GLOSSARY.md or docs/adr/, or when a decision may deserve an ADR."
---

# Domain modeling

`GLOSSARY.md` is the project's shared language and `docs/adr/` records its hard-to-reverse decisions. Every role reads them; this skill is for when a card **changes** the model, not just consumes it.

## Where things live

- One context: `GLOSSARY.md` at the repo root and `docs/adr/0001-slug.md`, `0002-slug.md`, ... Several contexts: a `GLOSSARY-MAP.md` at the root points to each context's own `GLOSSARY.md` and `docs/adr/`. Details in [GLOSSARY-FORMAT.md](GLOSSARY-FORMAT.md) and [ADR-FORMAT.md](ADR-FORMAT.md).
- Create files lazily, when the first term or decision needs writing.
- `GLOSSARY.md` holds domain terms only: no implementation details, no spec, no scratch notes.

## Who writes

| Role | Does |
|---|---|
| planner, refiner, researcher, reviewer, architect (read-only) | Read the files. Challenge and sharpen terms with the human. Put new or changed terms and ADR candidates in the deliverable (the plan's **Language** and **Decisions** sections); never edit the files. |
| implementer | Writes the plan's Language and Decisions into `GLOSSARY.md` and `docs/adr/` as part of the change. These are the only doc files it may add. |

## During the work

- **Challenge against the glossary.** A term that conflicts with `GLOSSARY.md`: say so at once and ask which is right.
- **Sharpen fuzzy language.** Propose one canonical term for a vague or overloaded one; list the rejected words as _Avoid_.
- **Invent concrete scenarios** that probe the edges between concepts, so the human has to be precise.
- **Cross-check the code.** When the human says how something works and the code disagrees, surface it.
- **Record terms as they resolve.** The implementer updates the file in the same change; read-only roles collect them in the deliverable as they are settled, not at the end.

## ADRs, sparingly

Record an ADR only when all three hold: **hard to reverse**, **surprising without context**, and **the result of a real trade-off**. Otherwise skip it. Read-only roles list the candidates; the implementer writes them in the format in [ADR-FORMAT.md](ADR-FORMAT.md).

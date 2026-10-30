---
name: grill-with-docs
description: "Grill the human about a change to, question about, or review of this project's code, aligned against the codebase, GLOSSARY.md and ADRs. Use for plans, refinements, reviews, explanations and architecture work in a repo; use grill-me for subjects outside the project."
---

# Grill with docs

`grilling`, pointed at a codebase. It is the same interview as `grill-me`, plus reading the code and the project's domain model, and collecting what the session settles about language and decisions.

Load **both** `grilling` (the interview, at the level the role names) and `domain-modeling` (the glossary and ADR discipline). Do not run an improvised interview from memory.

## Steps

1. **Read first.** `GLOSSARY.md` (or the `GLOSSARY-MAP.md` contexts), the ADRs in `docs/adr/` for the area, and the code the subject touches. Anything the code can answer is yours to find; never ask the human for it.
2. **Interview** with `grilling`. In addition:
   - A term the human uses conflicts with `GLOSSARY.md`: say so at once and ask which is right. A term is vague or overloaded: propose one canonical word and the words to avoid.
   - A domain relationship is described: invent one concrete edge-case scenario and ask what should happen.
   - The human states how something works and the code disagrees: surface it.
   - A decision would contradict an ADR: say which, and ask whether to reopen it.
3. **Collect as terms resolve**, not at the end:
   - New or changed terms, in glossary format (read-only roles put them in the deliverable; plans have a Language section).
   - ADR candidates that are hard to reverse, surprising and a real trade-off (a plan's Decisions section). Most sessions have none.
4. **Never edit** `GLOSSARY.md` or `docs/adr/` in a read-only role; the implementer writes them from the plan. Upstream's skill writes inline because it has no stages; here the writing waits for the implementation, so a rejected plan leaves no stray docs.

## Not this one

The subject is outside the project (a topic, a decision, a talk): use `grill-me`.

---
name: improve-codebase-architecture
description: "Scan a codebase for deepening opportunities and report them as a visual HTML architecture report. Use for an architecture card, when asked to find architectural friction, shallow modules, hard-to-test or hard-to-navigate code, or refactor candidates."
---

# Improve codebase architecture

Read-only. Surface architectural friction and propose **deepening opportunities**: refactors that turn shallow modules into deep ones, for testability and navigability. You find and present candidates; the human picks one and a Plan card grills and designs it. Do not propose interfaces.

Load `codebase-design` first and use its vocabulary exactly (**module, interface, depth, seam, adapter, leverage, locality**). Read `GLOSSARY.md` and the ADRs in the area first: domain names come from the glossary, and decisions in ADRs are not re-litigated.

## Steps

1. **Scope before you scan** (YAGNI). Deepening pays off where change is frequent.
   - The card names a direction (module, subsystem, pain point): take it.
   - Otherwise walk back the history (`git log --oneline`, `git log --stat` on a good stretch) to find the hot spots, the paths that keep changing, and look there first. Scattered changes with no hot spot: widen the net.
   - Still unclear, or the area is large: ask with `grilling` (MEDIUM; scope, areas off limits).
2. **Explore organically**, noting friction rather than following a checklist:
   - Understanding one concept means bouncing between many small modules.
   - Shallow modules: interface nearly as complex as the implementation.
   - Pure functions extracted only for testability while the real bugs hide in how they are called (no locality).
   - Tightly coupled modules leaking across their seams.
   - Parts untested or hard to test through their current interface.
3. **Apply the deletion test** to every suspected shallow module: would deleting it concentrate complexity (a deepening candidate) or only move it?
4. **Classify each candidate's dependencies** with the `codebase-design` skill's DEEPENING.md: in-process, local-substitutable, remote but owned, true external. It decides how the deepened module would be tested.
5. **Check ADRs.** A candidate that contradicts an ADR is listed only when the friction is real enough to reopen it; mark it with the ADR number and why.
6. **Write the report** by [references/report-format.md](references/report-format.md), starting from [references/template.html](references/template.html). Each candidate carries a before/after diagram, a recommendation strength, and a **Plan card idea**.
7. **Submit it** with `submit_deliverable`. Check the size first: under 80 KB.

## Plan card idea

A short paragraph the human can paste into a Plan card: the problem and who feels it, in glossary words, with the files involved. State the friction and what better looks like, not the new interface: the planner will grill the design, the seams and the tests.

## Vocabulary

If `GLOSSARY.md` lacks a domain term a candidate needs, list it under the report's **Language to add** and let the Plan card carry it into the plan; do not edit the file. Use the glossary's name for domain modules ("the Order intake module"), never "the FooBarHandler".

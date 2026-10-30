# Plan template

The implementer reads this document as PLAN.md and nothing else, so every requirement must be testable from the text alone. Markdown, these sections in this order:

1. **Intent and scope**: the problem, who has it, what is better afterwards (2-5 sentences, no solution). In and out of scope.
2. **Requirements**: R1, R2, ... in the patterns from the skill. Group by capability when there are more than about eight.
3. **Constraints**: each with its reason or source.
4. **Scenarios**: normal, alternative, failure, from the user's or caller's side.
5. **Boundaries**: the limits and edge cases, as example tables (condition, value, expected result).
6. **Qualities**: each with a number and unit, and how it is verified.
7. **Seams**: the public interfaces where the plan's behaviour will be tested (a route, a command, a context function, a message), as a caller sees them; confirmed with the human. One line each: what the seam catches and what it misses. A structural plan from an architecture report may name the module whose interface is being deepened. The implementer writes tests only at these seams.
8. **Language**: only new or changed domain terms, in the `GLOSSARY.md` format (term, one or two sentences, `_Avoid_` words). Terms already in `GLOSSARY.md` are not repeated; a conflict with it says which side wins and why. No implementation details. The implementer writes these into `GLOSSARY.md`.
9. **Decisions**: ADR candidates that are hard to reverse, surprising without context, and a real trade-off: a title and one to three sentences each. "None." is the usual answer. The implementer writes them to `docs/adr/`.
10. **Assumptions**: taken as true without checking; say what changes if one is false.
11. **Suggested slices**: an ordered list of vertical slices, each delivering observable behaviour at one of the seams above and building only on earlier ones. Name behaviour, never modules or files. Default to one slice.
12. **Open questions (design)**: for the implementer to settle in code.

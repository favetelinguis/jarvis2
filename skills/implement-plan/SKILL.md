---
name: implement-plan
description: "Implement an accepted PLAN.md test-first and report the result. Use when a kanban implementation step starts, when turning requirements into code, or when a plan has open design questions to settle in code."
---

# Implement a plan

Edit files and run checks. Do not commit, push, or alter PLAN.md.

## Steps

1. **Read.** PLAN.md, the project's instructions (AGENTS.md, CLAUDE.md, README), `GLOSSARY.md` and the ADRs, and the code the plan touches, so the result looks like the rest of the codebase and speaks its language. Find the project's own format, compile, lint and test commands; do not guess them.
2. **Stop when blocked.** PLAN.md missing, or a requirement contradictory or impossible: `ask_questions` with the options, then end your turn. Everything else, decide yourself.
3. **Work in vertical slices**, in the plan's suggested order or by dependency. Load `tdd` and follow it per slice: a failing test at one of the plan's Seams, minimal code to pass, next slice. A seam the plan lacks is a deviation to report, not a question.
4. **Settle design open questions** by choosing the simplest fit with the existing code. When a slice changes module boundaries, load `codebase-design` and apply its vocabulary. Record each choice for the report.
5. **Keep the change small.** Reuse before adding files, modules or dependencies. Comments say why, never what. Update existing docs only where the change made them wrong. Report unrelated problems instead of fixing them.
6. **Write the plan's language and decisions.** Load `domain-modeling`. Add the plan's Language terms to `GLOSSARY.md` and its Decisions to `docs/adr/NNNN-slug.md`, creating them if missing. Use the glossary's terms in names, tests and comments. These are the only doc files you may add; if you find the plan's terms or decisions wrong for the code, record that as a deviation.
7. **Verify.** Run the project's format, compile, lint and test commands until they pass, the full suite last. Name any check you could not run.
8. **Self-review.** Load `code-review` on your own diff. Fix every blocking and should-fix finding, then run the checks again. Two rounds at most. This is where refactoring happens, never inside the red → green loop.
9. **Report** with `submit_deliverable`, short, with only the parts that have content:
   - **Summary**: what changed, in a few lines.
   - **Tests run**: command and result, one line each.
   - **Deviations from the plan**: one line each, with why (including seams not in the plan).
   - **Design decisions**: the choices from step 4.
   - **Docs written**: glossary terms and ADRs added.
   - **Not run or unverified**: say so instead of claiming it passed.
   - **Follow-ups**: unrelated problems you saw.

If an external system is involved, load `external-integration-design` before step 3.

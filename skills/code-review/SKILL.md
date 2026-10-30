---
name: code-review
description: "Review a change (PR, branch, commit range, working-tree diff) against its intent and the repo's standards, and report a verdict. Use when reviewing someone else's change, or self-reviewing your own diff before reporting."
---

# Code review

Read-only. Never merge, edit, commit, push, comment on or approve a PR; the verdict is for the human.

## Steps

1. **Pin the change.** Fetch it yourself: `gh pr view` and `gh pr diff`, or `git diff <base>...<head>` with `git log --oneline`. Confirm the diff resolves and is not empty before reading on.
2. **Find the intent**: PR text, commit messages, linked issue, PLAN.md, the card. No intent anywhere: ask once, otherwise say so in the review and cap the verdict at COMMENT.
3. **Review on two axes**, reading the surrounding code and not only the hunks:
   - **Spec**: does the change do what the intent asks, no more, no less? Check every requirement and failure path; look for missing tests of changed behaviour.
   - **Standards**: does it follow the repo's documented standards (AGENTS.md, CONTRIBUTING, style docs) and its surrounding code? Skip what tooling already enforces. Add the judgement calls from [references/smells.md](references/smells.md); the repo wins where it differs.
   - **Language and decisions**: do names, tests and comments use `GLOSSARY.md` terms, with no synonym of a listed term? Does the change contradict an ADR? Are glossary and ADR additions real (domain terms only; ADRs that are hard to reverse, surprising and a trade-off)? Load `domain-modeling` when the change touches those files.
   - **Tests**: do they sit at seams, through public interfaces, with independent expected values? Judge them against the anti-patterns in the `tdd` skill.
4. **Run cheap checks** the project defines (format, compile, lint, focused tests). Record exactly what ran and the result; never claim a check you did not run.
5. **Classify each finding** with `file:line`, why it matters, and a suggested fix:
   - **Blocking**: wrong behaviour, data loss, security hole, spec violation, failing check, changed behaviour without a test, a contradicted ADR.
   - **Non-blocking**: maintainability, naming, simplification, nits worth saying. No nits a formatter catches.
6. **Pick the verdict**:
   - REQUEST CHANGES: at least one blocking finding.
   - COMMENT: no blocking finding, but non-blocking findings worth acting on, or something material you could not verify.
   - APPROVE: nothing blocking, nothing material left.

## Output

Deliver the review as Markdown. The first line is exactly `Verdict: APPROVE`, `Verdict: REQUEST CHANGES` or `Verdict: COMMENT`. Then, in order: **Summary** (what the change does and your overall judgement, 3 sentences), **Blocking issues**, **Non-blocking**, **Checks run**, **Questions for the author**. Write "None." under an empty section.

For a self-review, return findings only; no verdict line.

---
name: explain-change
description: "Explain a diff, commit range, branch or PR so a reader understands it before judging it. Use when a card asks to explain a change, or when describing what a change does and why."
---

# Explain a change

Read-only: explain, never edit, commit, push, comment on or approve.

## Steps

1. **Fetch it yourself**: `gh pr view` and `gh pr diff`, or `git diff <base>...<head>` with `git log`. Read the PR text and commit messages for the stated intent, then the code around the diff, not only the hunks.
2. **Fix the reader**: audience and depth come from the card or its answers. Unclear: one light round with `grilling`, otherwise assume a teammate who knows the repo but not this change.
3. **Find the essence**: the problem, the idea of the change in one picture, and one concrete toy example with before and after.
4. **Order the walkthrough by understanding, not by file**: contracts and types first, then core logic, then callers, then tests. Give each step the area or file, what changed, and why.
5. **Separate what the code does from what you infer** it is meant to do; say where you could not tell.

## Style

Plain words and short sentences. Define a term the first time you use it and keep one word per thing. Say what matters first. Cut anything decorative. Do not repeat the diff line by line.

## Output

Markdown, in this order: **Summary** (what and why, 3 sentences), **Walkthrough** (in reading order), **Behaviour changes** (what a user or caller sees differently), **Risks**, **Questions for the author**.

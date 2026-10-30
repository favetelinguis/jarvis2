---
name: agents-file
description: "Create, audit or update AGENTS.md while reading CLAUDE.md too. Use for an Agents file card or when a project's agent context file needs writing, pruning or merging."
---

# Agents file audit

Work read-only; the human applies the proposed root AGENTS.md. Read [BEST-PRACTICES.md](references/BEST-PRACTICES.md) before judging guidance; use [TEMPLATE.md](references/TEMPLATE.md) only when starting from scratch.

1. Read root AGENTS.md and CLAUDE.md if present. A CLAUDE.md containing only `@AGENTS.md` or symlinked to AGENTS.md is the same content, not a second source.
2. Audit every existing line: keep, stale, inferable from the environment, duplicate, or better in a skill, doc or hook. Account for every section; preserve useful content from both files without duplication.
3. Research the project and its history for missing conventions and gotchas that agents cannot infer. Ask only about unresolved human decisions.
4. Draft the smallest complete AGENTS.md. Every added line must pass: “Would an agent get this wrong without it?” Explain every added section, and every removed, rewritten or moved section, including material from CLAUDE.md. Never write either file yourself.
5. Check every existing section is kept or recorded in changes. Aim well below 200 lines and never exceed 32 KiB. Tell the human in changes what CLAUDE.md still needs (for example, importing AGENTS.md); only the human edits it. Current Claude Code can read AGENTS.md directly in some configurations, so check compatibility guidance rather than assuming.
6. Submit exactly one JSON object without fences. `content` is the complete non-empty file, not a patch. Each change has an action from add, rewrite, remove, move; a non-empty section and reason; and source AGENTS.md or CLAUDE.md. At most 100 changes.

`{"content":"# Instructions\n...","changes":[{"action":"remove","section":"Testing","reason":"The test command is already in the project configuration.","source":"CLAUDE.md"}]}`

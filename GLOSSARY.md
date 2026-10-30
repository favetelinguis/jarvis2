# Jarvis2

Control plane that runs Pi agents on kanban cards inside a dedicated Herdr session, and brings their questions and results back to the human.

## Language

**Card**:
A unit of work on the kanban board, created from an idea and worked on by agent runs.
_Avoid_: ticket, task, issue

**Kind**:
The type of a card (Plan, Research, Explain, Review, Refine, Slides, Architecture). It fixes the card's stages, question limit and deliverable type.
_Avoid_: card type, task type

**Stage**:
A phase of a card's work with its own role and deliverable. Only Plan cards have more than one: Planning, then Implementation.
_Avoid_: phase

**Step**:
A kind and stage pair. A role is assigned to each step.

**Role**:
A Markdown file in `roles/` that gives an agent its job, its restrictions and the skills to load, in order.

**Skill**:
Instructions in `skills/<name>/SKILL.md` that an agent loads on demand when its role or the task calls for them.

**Harness**:
An agent environment, such as Pi, that can connect to Jarvis2 to create cards.

**Run**:
One Pi agent session started for a card's stage or as a subagent, with its own Herdr pane.

**Subagent**:
A run spawned by another run to review its work and return a report.

**Spawner**:
The run that starts a subagent and receives its report.

**Fix review**:
A read-only review of an implementer's working-tree changes by a fix subagent.

**Round**:
One batch of questions an agent asks the human with `ask_questions`; rounds are numbered across the card.

**Grilling**:
The interview a role runs with the human before acting, through `ask_questions` in rounds. `grill-me` is the plain interview for subjects outside the project; `grill-with-docs` adds the codebase, `GLOSSARY.md` and ADRs.

**Grilling level**:
How much a role questions the human before acting: NONE, LIGHT, MEDIUM or HEAVY.

**Deliverable**:
The single result an agent submits for a stage with `submit_deliverable`: a plan, report, review, explanation, refined ticket, slide deck or architecture report.

**Plan**:
The Markdown deliverable of the Planning stage. Once accepted it is written to `PLAN.md` for the implementer.
_Avoid_: spec

**Session**:
The dedicated Herdr session named `jarvis2`, the only one Jarvis2 creates or uses.

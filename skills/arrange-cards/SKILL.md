---
name: arrange-cards
description: "Propose a card dependency graph from an Arrange snapshot. Use for an Arrange card when deciding which Scratch cards depend on other project cards and producing JSON for human review."
---

# Arrange dependencies

Read the supplied snapshot. Infer only dependencies supported by the card descriptions, existing edges and project context. Prefer no edge over a speculative edge. Do not change the board or files.

For each considered Scratch card, look for prerequisites, including existing project cards in the snapshot. A `plan` requirement is valid only for a Plan card when its accepted plan, rather than its completed implementation, is sufficient; otherwise use `done`. Avoid self-edges, duplicates, cycles and redundant transitive edges. Cross-worktree dependencies do not transfer code: explain any necessary integration in the reason.

Submit one JSON object, without Markdown fences:

```json
{"considered":["card-id"],"edges":[{"card":"dependent-id","blocked_by":"prerequisite-id","needs":"done","reason":"Why the prerequisite is needed"}]}
```

List every snapshot `considered` card you actually analyzed, even if you propose no edges for it. Only those IDs may be dependents. Both endpoints must be present in the snapshot. Keep reasons concise and propose at most 200 edges. The human can accept or reject each edge.

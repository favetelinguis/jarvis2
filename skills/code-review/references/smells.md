# Smell baseline

Judgement calls, each a labelled heuristic ("possible Feature Envy"), never a hard violation. A documented repo standard overrides any of them.

- **Mysterious name**: a name that does not say what the thing does or holds. Rename; if no honest name comes, the design is murky.
- **Duplicated code**: the same logic shape in more than one place in the change. Extract it.
- **Feature envy**: a function that reaches into another module's data more than its own. Move it.
- **Data clumps**: the same few fields travelling together. Give them a type.
- **Primitive obsession**: strings or integers standing in for a domain concept.
- **Long function or parameter list**: several levels of abstraction in one body.
- **Speculative generality**: options, layers or hooks nothing uses yet.
- **Pass-through**: a function or module that adds nothing over what it wraps.
- **Shotgun surgery**: one behaviour change that needs edits in many unrelated places.
- **Comments that restate code**, or stale comments and docs the change made wrong.
- **Error handling**: errors swallowed, handled where they cannot be handled, or secrets in logs and messages.
- **Untrusted input** used before it is validated where it enters.
- **Synonym of a glossary term** in a name, test or comment: use the `GLOSSARY.md` word.
- **Shallow module**: an interface nearly as complex as its implementation. Run the deletion test: if deleting it only moves complexity, it is a pass-through. Vocabulary in `codebase-design`.
- **Pure function extracted only for testability**, while the real behaviour is untested where it is called.
- **Implementation-coupled or tautological test**: mocks internal collaborators, asserts call counts, or recomputes the expected value the way the code does (see `tdd`).

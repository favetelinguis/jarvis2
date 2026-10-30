---
name: grill-me
description: "Grill the human about a subject that is not this project's code: an outside topic, a business or writing decision, a presentation, research on an external system. Use instead of grill-with-docs when no codebase, glossary or ADR is being aligned against."
---

# Grill me

The plain interview: `grilling`, nothing else. It is **stateless**: no repo reading for vocabulary, no glossary, no ADRs, nothing drafted for the docs.

## Steps

1. Load `grilling` and run it at the level the role names.
2. Facts come from the web, the sources the card names, and tools. Do not read `GLOSSARY.md` or ADRs to settle terms; the subject is not this project's language.
3. Unresolved points go into the deliverable as assumptions or open questions, as `grilling` says.

## Not this one

The subject is this working directory's code, behaviour or domain language: use `grill-with-docs`. If the card turns out to be about this project after all, switch and say so.

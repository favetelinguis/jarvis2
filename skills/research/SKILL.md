---
name: research
description: "Investigate a question against primary sources and report cited findings. Use when a card asks to research a topic, compare options, check what an API, library or system really does, or gather facts for a decision."
---

# Research

Read-only: gather facts, change nothing.

## Steps

1. **Pin the question.** One sentence, plus the decision the answer feeds and the depth wanted. Probe the gaps with `grilling`.
2. **Go to primary sources**: official docs, source code, specs, first-party APIs, and this repo's code and history. Use secondary write-ups only to find the primary source, then follow the claim back to the source that owns it. Use web search and fetch tools if you have them; say so if you do not.
3. **Cite every claim**: a URL, or `path:line` for code. Quote the decisive sentence when the wording matters. Note the version or date of the source when the answer could change.
4. **Label each statement** as **fact** (a source says it), **inference** (you conclude it, with the reasoning), or **unknown** (you could not find it). Never present an inference as a fact. When sources conflict, report both and say which you trust and why.
5. **Stop when the answer is decision-ready**, not when the topic is exhausted.

If the question concerns an outside system or provider, load `external-integration-design` and judge the findings against its checklist.

## Report

Markdown, in this order: **Question**, **Short answer** (3 sentences), **Findings** (grouped, each claim cited and labelled), **Confidence and unknowns**, **Recommended next steps**, **Sources** (numbered, referenced from the findings).

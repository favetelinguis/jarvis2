---
name: slide-deck
description: "Build a self-contained HTML slide deck for a Jarvis2 slides card. Use when creating or updating a deck, or when a deck is rejected for loading external resources or an invalid document."
---

# Jarvis2 slide decks

Start from [references/template.html](references/template.html), which already satisfies the contract below. Replace its example slides and title; keep its CSS and script unless a slide needs more.

## Contract

- One complete HTML document: begins with `<!doctype html>`, `<html>` and `<head>`, ends with `</html>`. Include charset, viewport and title.
- Inline CSS and JavaScript only. No `link`, `iframe`, `object`, `embed` or `base` elements, no external scripts, no `@import`, web fonts or network fetches. Use inline SVG or `data:` images. The preview is sandboxed and cannot load anything external.
- One `section class="slide"` per slide in a 16:9 stage scaled to the window.
- Arrow keys, Space, PageUp/PageDown, Home/End, click and tap navigate; `f` toggles fullscreen. A slide counter and progress bar show position, which is kept in `location.hash`. `@media print` prints one slide per page.

## Story

- **One idea per slide.** The title is the claim ("Retries multiply across layers"), not the topic ("Retries").
- **Shape**: title, the question or agenda, the content slides, a summary, sources, open questions.
- **Show, do not list.** Prefer a diagram, a table or one number over bullets. At most 5 short bullets per slide.
- **Large type, high contrast**, nothing under 24px at 1280x720.
- **Cite on the slide** where a claim appears, with a short source; full sources on the sources slide. Mark inference as inference.
- **Updating a deck**: read the current deck, apply the feedback, and submit the complete updated document.

Check the size before submitting: under 80 KB.

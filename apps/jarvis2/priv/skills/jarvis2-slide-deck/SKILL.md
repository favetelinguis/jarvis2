---
name: jarvis2-slide-deck
description: Build self-contained HTML slide decks for Jarvis2. Use when creating or updating a Jarvis2 slides deliverable.
---

# Jarvis2 slide decks

Submit one complete HTML document beginning with `<!doctype html>`, `<html>` and `<head>`, and ending with `</html>`. Include charset, viewport and title. Use inline CSS and JavaScript; do not use link, iframe, object, embed or base elements, external scripts, `@import`, web fonts or network fetches. Use inline SVG or data: images. The preview is sandboxed and cannot load external resources.

Use one `section class="slide"` per slide in a 16:9 stage scaled to the window. Support arrow keys, Space, PageUp/PageDown, Home/End and click or tap navigation; `f` toggles fullscreen. Show a slide counter and progress bar; keep position in `location.hash`. Use `@media print` for one slide per page.

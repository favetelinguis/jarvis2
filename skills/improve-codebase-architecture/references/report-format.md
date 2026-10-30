# Architecture report format

One self-contained HTML document, delivered with `submit_deliverable`. The board previews it in a sandbox with a restrictive CSP, so nothing external loads.

## Contract

- Begins with `<!doctype html>`, `<html>` and `<head>`, ends with `</html>`.
- Inline CSS and inline SVG only. No `link`, `iframe`, `object`, `embed`, `base`, no `script src`, no `@import`, web fonts, CDNs (no Tailwind, no Mermaid) or network fetches. `data:` images are allowed. Scripts are unnecessary.
- Under 80 KB.
- `template.html` already satisfies this: replace its example candidate, keep its CSS.

## Layout

- **Header**: repo, date, scope (what you looked at and why: named direction or hot spots), and a legend: solid box = module, dashed line = seam, red arrow = leakage, thick dark box = deep module. No introduction paragraph.
- **Candidates**, strongest first, one `<article>` each, in this order:
  - Title naming the deepening ("Collapse the Order intake pipeline").
  - Badges: recommendation strength (`Strong`, `Worth exploring`, `Speculative`) and dependency category (`in-process`, `local-substitutable`, `ports & adapters`, `mock`).
  - Files, monospaced.
  - Before / after diagram, side by side (see below).
  - **Problem**: one sentence. **Solution**: one sentence.
  - **Wins**: bullets of at most 6 words, in vocabulary terms: "locality: bugs concentrate in one module", "leverage: one interface, N call sites". Never "cleaner code".
  - **ADR callout** (only when relevant): amber box, "contradicts ADR-0007, but worth reopening because ...".
  - **Plan card idea**: a block the human can copy (see the skill).
- **Top recommendation**: one card with the candidate, one sentence why, and an anchor link to it.
- **Language to add**: only when `GLOSSARY.md` lacks terms the candidates need; each in glossary format.

## Diagrams

The diagrams carry the weight; prose stays sparse. If a diagram needs a paragraph, redraw it. Draw with inline SVG or styled `div`s, and vary the pattern:

- **Boxes and arrows**: modules as boxes, calls as arrows, leakage as red arrows, the after-state as one thick dark box with its former internals greyed inside.
- **Cross-section**: stacked bands for layers a call passes through; before, six thin bands doing nothing; after, one thick band.
- **Mass diagram**: per module, an interface rectangle and an implementation rectangle; shallow = interface nearly as tall as implementation, deep = short interface over a tall implementation.
- **Call-graph collapse**: a tree of nested calls collapsed into one box with the now-internal calls faded.

Keep each diagram about 320 px tall. Lean editorial: whitespace, one accent colour, red for leakage, amber for warnings, small uppercase labels inside diagrams.

## Tone

Plain, concise, and the architectural nouns come from `codebase-design`: "Order intake module is shallow: interface nearly matches the implementation." "Pricing leaks across the seam." "Two adapters justify the seam: HTTP in prod, in-memory in tests." Never component, service, unit, API, signature, boundary or layer for what those terms name. No hedging, no throat-clearing.

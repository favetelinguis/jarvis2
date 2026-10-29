# Plan: a `slides` ticket type with an in-board preview and a standalone HTML download

## Intent

Add a kanban card type, **Slides**. The agent researches a topic, either the card's working directory or any other
subject, and delivers a **single, self-contained HTML slide show**. The deliverable is not Markdown text.

- In the card panel below the board, the deck is shown **live and fully usable** (navigate, fullscreen), not as a
  `<pre>` dump.
- A **Save** button downloads the deck as one `.html` file that works offline from `file://` and can be shared.
- Everything else behaves like the existing kinds: Scratch → Agent → Awaiting user → Done, question rounds, reopen
  with feedback, archive and restore.

## Design decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Storage | The deck stays in `cards.deliverable` (text). `Kind` gains `:slides`. `kind` is a plain string column. | No migration; `Ecto.Enum` picks the new value up from `Kind.all/0`. |
| Preview | An `<iframe src="/kanban/cards/:id/slides">` in the card panel. It is not `srcdoc`, and the HTML is never rendered with `raw/1`. | The deck can be up to ~200 KB. It should not travel through the LiveView socket or sit in the diff. LiveView leaves an unchanged iframe alone, so the slide position survives board refreshes. |
| Isolation | The response carries `Content-Security-Policy: sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:`. There is no `allow-same-origin`. | The deck is agent-written and runs script. Without `allow-same-origin` it gets an opaque origin: no session cookie, no access to the app DOM or LiveView socket. Sandboxing by header also holds when the URL is opened in its own tab. |
| Self-contained | Three layers. The prompt says so; `Slides.validate/1` rejects remote references when the agent submits; the CSP blocks them at view time. | The agent gets an error and fixes the deck. A leak cannot reach the preview or a recipient. |
| Save | The same route with `?download=1` calls `send_download({:binary, html}, filename: "<slug>.html", content_type: "text/html")`. | One code path serves preview and download. The browser handles the save dialog. |
| Saved file | The file gets a `<meta http-equiv="Content-Security-Policy">` with the same policy, minus `sandbox`. | The shared file is also forbidden from loading remote resources or phoning home. |
| Size | `max_deliverable: 200_000` bytes; the prompt asks for 12–20 slides and under 80 KB. | The agent must emit the whole deck in one tool call. |
| Authentication | New route in the browser pipeline plus `Jarvis2Web.Auth` as a plug. | `/kanban/...` LiveViews are authenticated by `on_mount`; a controller route needs the plug form. |

## Scope

In scope: the slides kind and its prompt, validation, the serve/download route, preview and Save in the card panel,
tests, and a README note.

Out of scope: editing slides in the browser, saving the file into the working directory (Save is a browser download only), multiple decks per card,
PDF export (the deck's print CSS makes browser Print → PDF work), and themes.

## Changes

### 1. `Jarvis2.Kanban.Kind` (`apps/jarvis2/lib/jarvis2/kanban/kind.ex`)

Add `slides` to `@kinds` and to `all/0`.

```elixir
slides: %{
  label: "Slides",
  hint: "Topic or question to present; say 'this repo' to cover the working directory",
  max_questions: 4,
  max_body: 4_000,
  stages: [
    %{name: :main, noun: "slide deck", read_only: true, advance: nil,
      max_deliverable: 200_000, prompt: """..."""}
  ]
}
```

Prompt content, written as the other kinds are (terse, rule-based):

- Grilling level: MEDIUM. At most 2 rounds of 4 questions on audience, goal and takeaway, length, tone and depth, and
  whether the subject is the working directory or an outside topic. Skip anything already answered.
- Research the code, docs and web as the subject needs. Cite sources on the slides. Separate facts from inference.
- `submit_deliverable` **one complete HTML document, nothing else**: no Markdown, no code fence, no commentary.
- Hard rules:
  - One file. All CSS and JS are inline.
  - No `<link>`, no `<script src>`, no `@import`, no web fonts, no `fetch`.
  - Images are inline SVG or `data:` URIs.
  - Do not write files into the working directory.
- Presentation rules:
  - `<!doctype html>`, `<meta charset>`, `<meta name="viewport">`, and a `<title>`.
  - One `<section class="slide">` per slide, in a 16:9 stage that scales to the window.
  - Arrow keys, Space, PageUp/PageDown, Home/End, and click or tap navigation.
  - `f` toggles fullscreen.
  - Slide counter and progress bar.
  - Position kept in `location.hash`.
  - `@media print` shows one slide per page.
  - Readable at the back of a room (large type, high contrast, little text per slide).
- Structure: title slide, agenda or question, one idea per slide, a summary slide, then sources and open questions.

### 2. `Jarvis2.Kanban.Slides` (new, `apps/jarvis2/lib/jarvis2/kanban/slides.ex`)

A small deep module that holds all deck rules. `Kanban` and the controller only call it.

- `validate(html) :: :ok | {:error, message}`
  - It must look like a document: `<!doctype html>` first (case-insensitive, after trimming), and it must contain
    `<html`, `<head`, and `</html>`.
  - Reject external loads: `<link`, `<script ... src=`, `src=`/`poster=`/`srcset=` that is not `data:` or `#`,
    `url(` that is not `data:`, `@import`, `<iframe`, `<object`, `<embed`, and `<base`.
  - `<a href="https://…">` is allowed, so sources can be cited.
  - Error messages are specific and agent-readable: `"Deck loads external resource <snippet>; inline it or use a data: URI."`.
- `serve(html) :: iodata` injects the preview/save `<meta>` CSP right after `<head …>`.
- `filename(title) :: String.t()` slugs the card title to ASCII, with a fallback of `"slides"`, and appends `.html`.
- `csp_header/0` returns the preview header value.

`Kind` declares which kinds are decks (`deliverable: :html`, default `:markdown`), so `Kanban` does not hard-code
`:slides`.

### 3. `Jarvis2.Kanban.submit_deliverable/2` (`kanban.ex`)

After the byte-size check, run `Slides.validate/1` when the kind's deliverable type is `:html`. An invalid deck
returns `{:error, message}`. The existing MCP path already returns it to the agent, which stays in `:agent` and
can resubmit.

### 4. Reopen context (`Jarvis2.Kanban.Prompt`)

`Prompt.build/4` appends `"Previous <noun>: …"` truncated to the 6,000-byte task budget. For a deck that would be
broken HTML.

- For HTML kinds, replace the previous-deliverable text with a short pointer.
- On reopen or restore, `Kanban` writes the current deck to
  `<state_dir>/slides/<card_id>.html` (from `Application.fetch_env!(:jarvis2, :state_dir)`). The prompt says:
  `Current deck: <path>. Read it, apply the feedback, and submit a complete updated document.`
- This is outside the repository, so it cannot dirty the working tree. Reading it fits the read-only rules.
- The file is overwritten each time. It is a transient aid, not a record; `cards.deliverable` stays the source of truth.

### 5. Serve and download route

- `apps/jarvis2/lib/jarvis2_web/controllers/slides_controller.ex` (new), with `show/2`:
  1. `Kanban.get_card(id)` returns 404 unless the card is an HTML kind with a deliverable and is in `:done` or
     `:archive`. A deck that is still being edited is not shown.
  2. Without `download`, it sends `Slides.serve(html)` as `text/html; charset=utf-8` with the CSP header and
     `cache-control: no-store`.
  3. With `download=1`, it uses `send_download/3` and the same `serve/1` body.
- Router: add `pipeline :authenticated, do: plug Jarvis2Web.Auth`, and a scope with
  `pipe_through [:browser, :authenticated]` containing `get "/kanban/cards/:id/slides", SlidesController, :show`.
  It must not clash with the `/kanban/cards/:id` live route, so declare it before it or use a distinct prefix.

### 6. Card panel (`kanban_live/index.ex`, `priv/static/assets/app.css`)

- Extract `slides_viewer/1` as a function component. It takes `card` and renders:

  ```heex
  <iframe id={"deck-#{@card.id}"} class="slides-frame"
          src={~p"/kanban/cards/#{@card.id}/slides?v=#{:erlang.phash2(@card.deliverable)}"}
          sandbox="allow-scripts" allow="fullscreen" allowfullscreen
          title={@card.title} />
  <a class="button" href={~p"/kanban/cards/#{@card.id}/slides?download=1"}>Save</a>
  <a href={~p"/kanban/cards/#{@card.id}/slides"} target="_blank" rel="noopener">Open in new tab</a>
  ```

- `?v=` changes the `src` only when the deck itself changes, so board refreshes do not reload the frame.
- In the default (show) branch, use `slides_viewer/1` instead of the `<pre>` and Copy block when the kind is an HTML
  kind. Keep **Copy**, relabelled "Copy HTML", only if it stays trivial.
- In the `:reopen` branch, show the same viewer in place of `<pre>{@card.deliverable}</pre>`.
- CSS: `.slides-frame { width: 100%; aspect-ratio: 16/9; max-height: 80vh; border: 1px solid #8886; border-radius: .5rem; background: #fff }`.
- The iframe needs focus for keyboard navigation. Clicking the deck is enough for v1. Optionally add a small
  `FocusFrame` hook in `app.js` that focuses it on `load`.

### 7. MCP description (`mcp/server.ex`)

Extend the `submit_deliverable` description by one sentence: "For slides, content is one complete self-contained
HTML document." The tool is shared, so keep the text generic.

### 8. README

Add `Slides` to the kinds mention, and add a line to the safety model: deck HTML is untrusted agent output, served
sandboxed with a strict CSP; a saved deck contains a CSP meta and no external references.

## Tests

Follow `Jarvis2.DataCase`, `Jarvis2Web.ConnCase`, and the existing `kanban_test.exs` and `kanban_live_test.exs`.

- `Kanban.Slides` (unit): accepts a valid minimal deck. Rejects Markdown, a code-fenced deck, `<script src>`,
  `<link rel=stylesheet>`, `http` image `src`, `url(http…)`, `@import`, `<iframe>`, and `<base>`. Accepts `data:`
  images and an `<a href=https>`. `serve/1` injects the meta once. `filename/1` slugs `"Q3: A/B résumé!"` safely.
- `Kanban`:
  - Creating a slides card gets stage `:main`. The existing "stages by kind" loop covers this once `Kind.all/0`
    includes it.
  - `submit_deliverable` returns an error for an invalid deck and the card stays in `:agent`.
  - `submit_deliverable` returns an error above 200,000 bytes.
  - A valid deck moves the card to `:done`.
- `Prompt`: a slides card with a 10,000-char deliverable stays within 6,000 bytes. The prompt contains the deck path
  and not the HTML. The existing per-kind loop (`kanban_test.exs` ~L295) must be extended with `:slides`.
- `SlidesController`:
  - Signed out redirects to `/login`.
  - Done slides card: 200, `text/html`, a CSP header containing `sandbox allow-scripts` and no `allow-same-origin`,
    and a body containing the meta.
  - `?download=1` sends `content-disposition: attachment; filename="….html"`.
  - 404 for an unknown id, a non-deck kind, a card with no deliverable, and a card still in `:agent`.
- `KanbanLive`: a done slides card shows `iframe.slides-frame[sandbox="allow-scripts"]`, a Save link with
  `download=1`, and no `pre`. It does not show `allow-same-origin`. A reopen page also shows the frame.
  Regression: a refresh broadcast does not change the iframe `src`.

## Verification

1. `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo`, and `mix test` from the umbrella
   root. Report anything that cannot run.
2. Manual (needs a live session; follow the README safety model):
   - Create a Slides card for "this repo".
   - Answer the questions.
   - When it is Done, check the deck in the panel: arrows, `f`, and the hash.
   - Click **Save**, then open the file from `file://` with the network disabled. It must still render fully.
   - Open a deck that references a remote image. The agent submission must be rejected.
   - In the browser console, confirm the frame cannot read `parent.document`.
   - Reopen with feedback. The agent should read the saved file and submit an updated deck.

## Risks and open questions

- **Agent output size.** 200 KB is about 50k tokens in one tool call. Decided: keep 200,000 as the hard cap and
  80 KB as the prompted target. Lower the cap if real runs are truncated or slow.
- **Validator false positives.** Regex checks can reject legitimate decks, for example the text `src=` inside a code
  slide. The error message must name the snippet. Tighten to a tag-aware parse (`Floki`, if already a dependency)
  only if this proves noisy.
- **Board load (not the preview).** This is about the kanban board's card list, not the iframe. `Kanban.list_cards/0`
  loads every column of every card, including the full `deliverable` text, on each refresh, though the board only
  needs titles. The iframe fetches the deck separately, only for the open card. Follow-up: select the board query
  without `deliverable` and `accepted_plan`. Measure first; not part of this change.
- **Save target.** Decided: browser download only. No copy is written into the working directory.
- **Fullscreen and keys inside a sandboxed frame** differ slightly between browsers. Verify in Firefox and Chromium.
- **File name.** `plan.md` at the repository root already holds a different plan, so this one is `plan-slides.md`.

defmodule Jarvis2.Kanban.Kind do
  @moduledoc false

  @common """
  No chat questions, ask_human or request_approval. ask_questions then END YOUR TURN; answers follow. Questions: unnumbered title, body, recommended, options (up to 6 alternatives). Provide alternatives whenever applicable. Find facts; never guess decisions. submit_deliverable the full result.
  Keep your own chat output minimal: only tool content is read; no narration or repetition.
  """
  @read_only "Do not edit files, commit, push, comment on or approve a PR."

  @implementation %{
    name: :implementation,
    noun: "implementation report",
    read_only: false,
    max_deliverable: 20_000,
    advance: nil,
    prompt: """
    Read PLAN.md in the working directory and implement it. Edit files and run tests; do not commit, push, or alter PLAN.md. For unresolved design questions use ask_questions and end your turn. Finish with submit_deliverable an implementation report: what changed, tests run, deviations from the plan, and follow-ups.
    """
  }

  @kinds %{
    plan: %{
      label: "Plan",
      hint: "Describe your idea",
      max_questions: 8,
      max_body: 2_000,
      stages: [
        %{
          name: :planning,
          noun: "plan",
          read_only: false,
          advance: %{to: :implementation, label: "Accept plan"},
          max_deliverable: 20_000,
          prompt: """
          You are the requirements engineer for this card. Turn the loose idea into a refined plan. Start from the problem, not a solution. Grilling level: HEAVY; unlimited rounds, up to 8 questions per round.
          Explore the need behind proposed solutions; keep insisted solutions as constraints with reasons. Ask who benefits, what they do today, and what better means. Cover normal, alternative and failure scenarios. Explore nothing, one, many, limits, duplicates, concurrency, restart, invalid or hostile input, permissions, and unavailable or slow external systems. Make quality requirements measurable or drop them. Define domain terms in a glossary, resolve synonyms, and check the code. Surface conflicts and get assumptions confirmed. Do not ask about modules, files, types or signatures; record design questions as open questions.
          Keep decisions as a tree; each round ask the whole frontier whose prerequisites are settled. When decisions are complete, ask one final question playing back intent and scope, recommending "Yes, that is it". Only after confirmation submit Markdown: Intent and scope, Requirements, Constraints with reasons, Scenarios, Boundaries, Qualities with numbers, Glossary, Assumptions, and Open questions (design).
          """
        },
        @implementation
      ]
    },
    research: %{
      label: "Research",
      hint: "Enter a question or topic",
      max_questions: 4,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "report",
          read_only: true,
          advance: nil,
          max_deliverable: 20_000,
          prompt: """
          Research the card's question. Grilling level: MEDIUM, at most 2 rounds of 4 questions on question, decision, depth, budget, knowns and sources; skip answered questions. Research code, docs and web if available. Cite every claim; distinguish facts, inferences and unknowns. Report: Question, Short answer (3 sentences), Findings, Confidence and unknowns, Recommended next steps.
          """
        }
      ]
    },
    explain: %{
      label: "Explain",
      hint: "Enter a diff, commit range, branch or PR link",
      max_questions: 2,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "explanation",
          read_only: true,
          advance: nil,
          max_deliverable: 20_000,
          prompt: """
          Explain the card's diff, range, branch or PR; fetch it yourself with git or gh. Grilling level: LIGHT: normally none; at most one round of 2 questions if input is missing or reader unclear (audience, depth). Explanation: Summary (what and why, 3 sentences), Walkthrough in reading order (area/file, what and why), Behaviour changes, Risks, Questions for the author.
          """
        }
      ]
    },
    review: %{
      label: "Review",
      hint: "Enter a PR link or number, branch or commit range",
      max_questions: 3,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "review",
          read_only: true,
          advance: nil,
          max_deliverable: 20_000,
          prompt: """
          Review the PR, branch or range. Never merge; verdict is for the human. Grilling level: LIGHT-MEDIUM, 1 round max, 3 questions on missing intent, focus, strictness. Fetch changes; run cheap checks. First line exactly "Verdict: APPROVE", "Verdict: REQUEST CHANGES" or "Verdict: COMMENT". Then Summary, Blocking issues (file:line, why, fix), Non-blocking, Checks run, Questions for the author.
          """
        }
      ]
    },
    slides: %{
      label: "Slides",
      hint: "Topic or question to present; say 'this repo' to cover the working directory",
      max_questions: 4,
      max_body: 4_000,
      deliverable: :html,
      stages: [
        %{
          name: :main,
          noun: "slide deck",
          read_only: true,
          advance: nil,
          max_deliverable: 200_000,
          prompt: """
          Create a slide deck. Grilling level: MEDIUM, at most 2 rounds of 4 questions about audience, goal and takeaway, length, tone, depth, and whether the subject is this working directory or an outside topic; skip answered questions. Research code, docs and web as needed. Cite sources on slides; separate facts from inference.
          submit_deliverable one complete HTML document, nothing else: no Markdown, code fence or commentary. Target 12–20 slides and under 80 KB. One file with inline CSS and JS only: no link tags, script src, @import, web fonts or fetch. Use inline SVG or data: images. Do not write files in the working directory.
          Include <!doctype html>, meta charset, viewport and title. Use one section class="slide" per slide in a 16:9 stage scaled to the window. Support arrow keys, Space, PageUp/PageDown, Home/End and click or tap navigation; f toggles fullscreen. Show a slide counter and progress bar; keep position in location.hash. Use @media print for one slide per page. Use large type, high contrast and little text per slide. Include a title, agenda or question, one idea per slide, summary, sources and open questions.
          """
        }
      ]
    },
    refine: %{
      label: "Refine",
      hint: "Paste the Jira ticket text",
      max_questions: 4,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "refined ticket",
          read_only: true,
          advance: nil,
          max_deliverable: 4_000,
          prompt: """
          Turn the pasted Jira ticket into a short description; do not design a solution. Grilling level: MEDIUM, at most 2 rounds of 4 questions on unclear needs, done, scope and dependencies. Check code for facts. Plain text under 1500 bytes: Goal (one sentence), Work to do, Out of scope, Acceptance criteria, Open questions. Headings end in a colon; use - bullets, no tables or code fences.
          """
        }
      ]
    }
  }

  def all, do: [:plan, :research, :explain, :review, :refine, :slides]
  def get(kind), do: Map.fetch!(@kinds, kind)
  def deliverable_type(kind), do: Map.get(get(kind), :deliverable, :markdown)
  def stages(kind), do: get(kind).stages
  def initial_stage(kind), do: hd(stages(kind)).name
  def stage(kind, name), do: Enum.find(stages(kind), &(&1.name == name))
  def noun(kind), do: noun(kind, initial_stage(kind))
  def noun(kind, name), do: stage(kind, name).noun

  def protocol(kind, name) do
    stage = stage(kind, name)
    rules = if stage.read_only, do: @read_only <> "\n", else: ""
    String.trim(@common) <> "\n" <> rules <> String.trim(stage.prompt)
  end
end

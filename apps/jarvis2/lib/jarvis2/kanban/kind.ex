defmodule Jarvis2.Kanban.Kind do
  @moduledoc false

  @common """
  No chat questions, ask_human or request_approval. ask_questions then END YOUR TURN; answers follow. Questions: unnumbered title, body, recommended, options (up to 6 alternatives). Provide alternatives whenever applicable. Find facts; never guess decisions. submit_deliverable the full result.
  Keep your own chat output minimal: only tool content is read; no narration or repetition.
  """
  @read_only "Do not edit files, commit, push, comment on or approve a PR."

  @kinds %{
    plan: %{
      label: "Plan",
      noun: "plan",
      hint: "Describe your idea",
      max_questions: 8,
      max_body: 2_000,
      max_deliverable: 20_000,
      prompt: """
      You are the requirements engineer for this card. Turn the loose idea into a refined plan. Start from the problem, not a solution. Grilling level: HEAVY; unlimited rounds, up to 8 questions per round.
      Explore the need behind proposed solutions; keep insisted solutions as constraints with reasons. Ask who benefits, what they do today, and what better means. Cover normal, alternative and failure scenarios. Explore nothing, one, many, limits, duplicates, concurrency, restart, invalid or hostile input, permissions, and unavailable or slow external systems. Make quality requirements measurable or drop them. Define domain terms in a glossary, resolve synonyms, and check the code. Surface conflicts and get assumptions confirmed. Do not ask about modules, files, types or signatures; record design questions as open questions.
      Keep decisions as a tree; each round ask the whole frontier whose prerequisites are settled. When decisions are complete, ask one final question playing back intent and scope, recommending "Yes, that is it". Only after confirmation submit Markdown: Intent and scope, Requirements, Constraints with reasons, Scenarios, Boundaries, Qualities with numbers, Glossary, Assumptions, and Open questions (design).
      """
    },
    research: %{
      label: "Research",
      noun: "report",
      hint: "Enter a question or topic",
      max_questions: 4,
      max_body: 4_000,
      max_deliverable: 20_000,
      prompt: """
      Research the card's question. Grilling level: MEDIUM, at most 2 rounds of 4 questions on question, decision, depth, budget, knowns and sources; skip answered questions. Research code, docs and web if available. Cite every claim; distinguish facts, inferences and unknowns. Report: Question, Short answer (3 sentences), Findings, Confidence and unknowns, Recommended next steps.
      """
    },
    explain: %{
      label: "Explain",
      noun: "explanation",
      hint: "Enter a diff, commit range, branch or PR link",
      max_questions: 2,
      max_body: 4_000,
      max_deliverable: 20_000,
      prompt: """
      Explain the card's diff, range, branch or PR; fetch it yourself with git or gh. Grilling level: LIGHT: normally none; at most one round of 2 questions if input is missing or reader unclear (audience, depth). Explanation: Summary (what and why, 3 sentences), Walkthrough in reading order (area/file, what and why), Behaviour changes, Risks, Questions for the author.
      """
    },
    review: %{
      label: "Review",
      noun: "review",
      hint: "Enter a PR link or number, branch or commit range",
      max_questions: 3,
      max_body: 4_000,
      max_deliverable: 20_000,
      prompt: """
      Review the PR, branch or range. Never merge; verdict is for the human. Grilling level: LIGHT-MEDIUM, 1 round max, 3 questions on missing intent, focus, strictness. Fetch changes; run cheap checks. First line exactly "Verdict: APPROVE", "Verdict: REQUEST CHANGES" or "Verdict: COMMENT". Then Summary, Blocking issues (file:line, why, fix), Non-blocking, Checks run, Questions for the author.
      """
    },
    refine: %{
      label: "Refine",
      noun: "refined ticket",
      hint: "Paste the Jira ticket text",
      max_questions: 4,
      max_body: 4_000,
      max_deliverable: 4_000,
      prompt: """
      Turn the pasted Jira ticket into a short description; do not design a solution. Grilling level: MEDIUM, at most 2 rounds of 4 questions on unclear needs, done, scope and dependencies. Check code for facts. Plain text under 1500 bytes: Goal (one sentence), Work to do, Out of scope, Acceptance criteria, Open questions. Headings end in a colon; use - bullets, no tables or code fences.
      """
    }
  }

  def all, do: [:plan, :research, :explain, :review, :refine]
  def get(kind), do: Map.fetch!(@kinds, kind)
  def noun(kind), do: get(kind).noun

  def protocol(kind) do
    kind_rules = if kind == :plan, do: "", else: @read_only <> "\n"
    String.trim(@common) <> "\n" <> kind_rules <> String.trim(get(kind).prompt)
  end
end

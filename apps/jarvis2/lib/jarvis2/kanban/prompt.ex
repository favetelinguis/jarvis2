defmodule Jarvis2.Kanban.Prompt do
  @moduledoc false

  @protocol """
  You are the requirements engineer for this card. Turn the loose idea into a refined plan. Start from the problem, not a solution.

  Explore the need behind proposed solutions; keep insisted solutions as constraints with reasons. Ask who benefits, what they do today, and what better means. Cover normal, alternative and failure scenarios. Explore nothing, one, many, limits, duplicates, concurrency, restart, invalid or hostile input, permissions, and unavailable or slow external systems. Make quality requirements measurable or drop them. Define domain terms in a glossary, resolve synonyms, and check the code. Surface conflicts and get assumptions confirmed. Do not ask about modules, files, types or signatures; record design questions as open questions.

  Never ask in chat or use ask_human or request_approval for this interview. Ask only with ask_questions, then END YOUR TURN. Answers arrive as your next message. Keep decisions as a tree; each round ask the whole frontier whose prerequisites are settled, up to 8 questions. Each question is an object with unnumbered title, body, recommended and optional options (list of strings); Jarvis2 numbers them. Read the repository and docs for facts; human decisions must not be guessed. When decisions are complete, ask one final question playing back intent and scope, recommending "Yes, that is it". Only after confirmation call submit_plan with Markdown: Intent and scope, Requirements, Constraints with reasons, Scenarios, Boundaries, Qualities with numbers, Glossary, Assumptions, and Open questions (design).
  """

  def build(card, rounds \\ [], feedback \\ nil) do
    prior_feedback = if Ecto.assoc_loaded?(card.feedback), do: card.feedback, else: []

    history =
      (rounds ++ prior_feedback)
      |> Enum.sort_by(&(&1.inserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
      |> Enum.map(&history_item/1)
      |> Enum.reject(&(&1 == ""))

    feedback = if feedback, do: "Reopen feedback: " <> feedback <> "\n", else: ""
    history_budget = max(0, 1_700 - byte_size(feedback))
    plan_reserve = if card.plan, do: min(300, history_budget), else: 0
    context = history_text(history, history_budget - plan_reserve)

    plan =
      if card.plan,
        do: truncate("\nPrevious plan:\n" <> card.plan, history_budget - byte_size(context)),
        else: ""

    String.trim(@protocol) <>
      "\n\nCard: " <>
      card.title <>
      "\nIdea: " <>
      (card.body || "") <>
      "\n" <> feedback <> context <> plan
  end

  def answers(round) do
    lines =
      Enum.map_join(round.questions, "\n", fn q ->
        answer = round.answers[q["id"]]

        response =
          if answer["kind"] == "recommended",
            do: "accepted your recommendation: " <> answer["text"],
            else: answer["text"]

        note =
          if answer["note"] in [nil, ""], do: "", else: " (because: " <> answer["note"] <> ")"

        q["id"] <> " - " <> q["title"] <> ": " <> response <> note
      end)

    "Answers to round #{round.number}:\n" <>
      lines <>
      "\nContinue the interview: ask the next round, or play back and submit_plan if nothing is left."
  end

  def reopen(text),
    do:
      "The human reopened this card with this feedback: " <>
        text <>
        ". Re-read your plan, ask what is missing or unclear with ask_questions, or submit an updated plan."

  defp history_item(%Jarvis2.Kanban.Round{} = round) do
    if round.status == :answered and map_size(round.answers) > 0, do: answers(round), else: ""
  end

  defp history_item(%Jarvis2.Kanban.Feedback{text: text}), do: "Earlier feedback: " <> text

  defp history_text(items, budget) do
    Enum.reduce_while(items, "", fn item, acc ->
      separator = if acc == "", do: "", else: "\n"
      remaining = budget - byte_size(acc) - byte_size(separator)

      cond do
        byte_size(item) <= remaining -> {:cont, acc <> separator <> item}
        acc == "" -> {:halt, truncate(item, max(remaining, 0))}
        true -> {:halt, acc}
      end
    end)
  end

  defp truncate(text, bytes) when byte_size(text) <= bytes, do: text

  defp truncate(text, bytes),
    do:
      text
      |> String.graphemes()
      |> Enum.reduce_while("", fn char, acc ->
        if byte_size(acc) + byte_size(char) <= bytes, do: {:cont, acc <> char}, else: {:halt, acc}
      end)
end

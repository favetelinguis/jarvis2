defmodule Jarvis2.Kanban.Prompt do
  @moduledoc false

  alias Jarvis2.Kanban.Kind

  def build(card, rounds \\ [], feedback \\ nil) do
    prior_feedback = if Ecto.assoc_loaded?(card.feedback), do: card.feedback, else: []

    history =
      (rounds ++ prior_feedback)
      |> Enum.sort_by(&(&1.inserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
      |> Enum.map(&history_item/1)
      |> Enum.reject(&(&1 == ""))

    feedback = if feedback, do: "Reopen feedback: " <> feedback <> "\n", else: ""

    base =
      Kind.protocol(card.kind) <>
        "\n\nCard: " <> card.title <> "\nIdea: " <> (card.body || "") <> "\n" <> feedback

    history_budget = max(0, 6_000 - byte_size(base))
    reserve = if card.deliverable, do: min(300, history_budget), else: 0
    context = history_text(history, history_budget - reserve)

    previous =
      if card.deliverable,
        do:
          truncate(
            "\nPrevious " <> Kind.noun(card.kind) <> ":\n" <> card.deliverable,
            history_budget - byte_size(context)
          ),
        else: ""

    base <> context <> previous
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
      "\nContinue: ask the next round if the grilling level allows, or submit_deliverable if nothing is left. Chat output stays minimal."
  end

  def reopen(text, kind) do
    noun = Kind.noun(kind)

    "The human reopened this card with this feedback: " <>
      text <>
      ". Re-read your #{noun}, ask what is missing or unclear with ask_questions, or submit an updated #{noun}. Chat output stays minimal."
  end

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

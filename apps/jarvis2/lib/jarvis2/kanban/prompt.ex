defmodule Jarvis2.Kanban.Prompt do
  @moduledoc false

  alias Jarvis2.Kanban.{Kind, Slides}

  def build(card, rounds, feedback, opts) do
    role = Keyword.fetch!(opts, :role)
    budget = Jarvis2.Herdr.Actions.prompt_limit()
    prior_feedback = if Ecto.assoc_loaded?(card.feedback), do: card.feedback, else: []

    history =
      (rounds ++ prior_feedback)
      |> Enum.filter(fn item ->
        card.stage != :implementation or in_stage?(item, card.stage_started_at)
      end)
      |> Enum.sort_by(&(&1.inserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
      |> Enum.map(&history_item(&1, card.stage))
      |> Enum.reject(&(&1 == ""))

    deck =
      if card.deliverable && Kind.deliverable_type(card.kind) == :html,
        do: "\n" <> deck_pointer(card.id) <> "\n",
        else: ""

    base =
      Kind.protocol(card.kind, card.stage, role.prompt) <>
        "\n\nCard: " <>
        card.title <>
        "\nIdea: " <>
        (card.body || "") <> "\n" <> feedback_text(feedback, opts) <> deck

    base <> optional_context(card, history, max(0, budget - byte_size(base)))
  end

  defp optional_context(card, history, history_budget) do
    has_previous =
      (card.stage != :implementation and card.deliverable) &&
        Kind.deliverable_type(card.kind) != :html

    reserve = if has_previous, do: min(300, history_budget), else: 0
    context = history_text(history, history_budget - reserve)

    previous =
      if has_previous,
        do:
          truncate(
            "\nPrevious " <> Kind.noun(card.kind, card.stage) <> ":\n" <> card.deliverable,
            history_budget - byte_size(context)
          ),
        else: ""

    context <> previous
  end

  defp in_stage?(%{inserted_at: %DateTime{} = inserted_at}, %DateTime{} = started_at),
    do: DateTime.compare(inserted_at, started_at) != :lt

  defp in_stage?(_, _), do: false

  defp feedback_text(nil, _opts), do: ""

  defp feedback_text(feedback, opts) do
    lead =
      if opts[:restored],
        do:
          "Restored from archive; your earlier conversation was reloaded if it still exists. Reason: ",
        else: "Reopen feedback: "

    lead <> feedback <> "\n"
  end

  def answers(round, stage \\ nil) do
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

    continuation =
      if stage == :implementation do
        "Continue implementing PLAN.md, ask_questions if needed, or submit_deliverable with the implementation report."
      else
        "Continue: ask the next round if the grilling level allows, or submit_deliverable if nothing is left."
      end

    "Answers to round #{round.number}:\n" <> lines <> "\n" <> continuation
  end

  def reopen(text, kind, stage \\ nil, card_id \\ nil) do
    noun = Kind.noun(kind, stage || Kind.initial_stage(kind))

    deck =
      if card_id && Kind.deliverable_type(kind) == :html,
        do: " " <> deck_pointer(card_id),
        else: ""

    "The human reopened this card with this feedback: " <>
      text <>
      ". Re-read your #{noun}, ask what is missing or unclear with ask_questions, or submit an updated #{noun}." <>
      deck
  end

  defp deck_pointer(id),
    do:
      "Current deck: #{Slides.path(id)}. Read it, apply the feedback, and submit a complete updated document."

  defp history_item(%Jarvis2.Kanban.Round{} = round, stage) do
    if round.status == :answered and map_size(round.answers) > 0,
      do: answers(round, stage),
      else: ""
  end

  defp history_item(%Jarvis2.Kanban.Feedback{text: text}, _stage),
    do: "Earlier feedback: " <> text

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

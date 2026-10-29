defmodule Jarvis2.Kanban.Round do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "card_rounds" do
    field :card_id, :binary_id
    field :number, :integer
    field :questions, {:array, :map}, default: []
    field :answers, :map, default: %{}
    field :status, Ecto.Enum, values: [:open, :answered, :cancelled], default: :open
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def valid_questions?(questions, max)
      when is_list(questions) and questions != [] and length(questions) <= max do
    Enum.all?(questions, fn q ->
      is_map(q) and bounded?(get(q, :title), 120) and bounded?(get(q, :body), 1_000) and
        bounded?(get(q, :recommended), 500) and valid_options?(get(q, :options) || [])
    end)
  end

  def valid_questions?(_, _), do: false

  def normalize_questions(questions, first) do
    questions
    |> Enum.with_index(first)
    |> Enum.map(fn {q, n} ->
      %{
        "id" => "Q#{n}",
        "title" => get(q, :title),
        "body" => get(q, :body),
        "recommended" => get(q, :recommended),
        "options" => get(q, :options) || []
      }
    end)
  end

  def valid_answers?(round, answers) when is_map(answers) do
    questions = Map.new(round.questions, &{&1["id"], &1})

    Enum.all?(answers, fn {id, answer} ->
      q = questions[id]
      is_binary(id) and is_map(q) and is_map(answer) and valid_answer?(q, answer)
    end)
  end

  def valid_answers?(_, _), do: false

  def complete?(round),
    do:
      Enum.all?(round.questions, fn q ->
        case round.answers[q["id"]] do
          %{} = answer -> valid_answer?(q, answer) and complete_answer?(q, answer)
          _ -> false
        end
      end)

  defp valid_answer?(q, answer) do
    note = get(answer, :note) || ""

    is_binary(note) and byte_size(note) <= 500 and
      valid_choice?(q, get(answer, :kind), get(answer, :text))
  end

  defp valid_choice?(q, "recommended", text), do: text == q["recommended"]
  defp valid_choice?(q, "option", text), do: text in q["options"]
  defp valid_choice?(_q, "custom", text), do: is_binary(text) and byte_size(text) <= 500
  defp valid_choice?(_q, kind, text) when kind in [nil, ""], do: text in [nil, ""]
  defp valid_choice?(_, _, _), do: false

  defp complete_answer?(q, answer) do
    case get(answer, :kind) do
      "recommended" -> get(answer, :text) == q["recommended"]
      "option" -> get(answer, :text) in q["options"]
      "custom" -> bounded?(get(answer, :text), 500)
      _ -> false
    end
  end

  defp valid_options?(options) when is_list(options) and length(options) <= 6,
    do: Enum.all?(options, &bounded?(&1, 100))

  defp valid_options?(_), do: false
  defp bounded?(s, max), do: is_binary(s) and byte_size(s) <= max and String.trim(s) != ""
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

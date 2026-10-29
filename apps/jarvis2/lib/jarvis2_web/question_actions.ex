defmodule Jarvis2Web.QuestionActions do
  @moduledoc "Answering an inbox question from a LiveView."
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Jarvis2.Questions

  def answer(socket, %{"id" => id, "answer" => answer}), do: answer(socket, id, answer)
  def answer(socket, %{"question_id" => id, "answer" => answer}), do: answer(socket, id, answer)
  def answer(socket, _params), do: socket

  defp answer(socket, id, answer) do
    with %Questions.Question{} = question <- Questions.get(id),
         {:ok, _} <- Questions.answer(question, answer) do
      socket
    else
      nil -> put_flash(socket, :error, "That question no longer exists.")
      {:error, :invalid_answer} -> put_flash(socket, :error, "That answer is not allowed.")
      {:error, :not_pending} -> put_flash(socket, :error, "That question was already closed.")
    end
  end
end

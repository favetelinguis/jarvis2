defmodule Jarvis2.Runs.Prompt do
  @moduledoc "The first message a run's agent receives."

  def build(run), do: run.task
end

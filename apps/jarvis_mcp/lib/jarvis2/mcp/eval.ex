defmodule Jarvis2.MCP.Eval do
  @moduledoc false

  def run(code) when is_binary(code) do
    timeout = Application.get_env(:jarvis2, :eval_timeout_ms, 5_000)

    cond do
      not Application.get_env(:jarvis2, :allow_eval, false) ->
        {:error, "Elixir evaluation is disabled"}

      byte_size(code) > 16_384 ->
        {:error, "code is too long"}

      not is_integer(timeout) or timeout < 10 or timeout > 10_000 ->
        {:error, "invalid evaluation timeout"}

      true ->
        evaluate(code, timeout)
    end
  end

  defp evaluate(code, timeout) do
    task =
      Task.Supervisor.async_nolink(Jarvis2.TaskSupervisor, fn ->
        try do
          {value, _bindings} = Code.eval_string(code)
          {:ok, value |> inspect(limit: 50, printable_limit: 2_000) |> String.slice(0, 4_096)}
        rescue
          _ -> {:error, :failed}
        catch
          _, _ -> {:error, :failed}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, %{result: result}}
      {:ok, {:error, _}} -> {:error, "evaluation failed"}
      {:exit, _} -> {:error, "evaluation failed"}
      nil -> {:error, "evaluation timed out"}
    end
  end
end

defmodule Jarvis2.MCP.MixRunner do
  @moduledoc false

  @commands %{
    "test" => ["test"],
    "compile" => ["compile"],
    "format --check-formatted" => ["format", "--check-formatted"]
  }
  @output_limit 16_384

  def tasks, do: Enum.sort(Map.keys(@commands))

  @doc "The one project Mix tasks may run in."
  def project_root,
    do: Application.get_env(:jarvis2, :mix_project_dir, File.cwd!()) |> Path.expand()

  def run(task, requested_project) do
    root = project_root()

    project =
      if is_binary(requested_project), do: Path.expand(requested_project, root), else: root

    mix = Application.get_env(:jarvis2, :mix_executable) || System.find_executable("mix")
    timeout = System.find_executable("timeout")
    timeout_ms = Application.get_env(:jarvis2, :mix_timeout_ms, 60_000)

    cond do
      not Map.has_key?(@commands, task) ->
        {:error, "Mix task is not allowed"}

      project != root or not File.dir?(root) ->
        {:error, "project must be the configured trusted project"}

      not is_binary(mix) or Path.type(mix) != :absolute or not is_binary(timeout) ->
        {:error, "Mix runner prerequisites are unavailable"}

      not is_integer(timeout_ms) or timeout_ms < 10 or timeout_ms > 110_000 ->
        {:error, "invalid Mix runner timeout"}

      true ->
        case Registry.register(Jarvis2.MixRegistry, :run, nil) do
          {:ok, _} ->
            try do
              worker = Jarvis2.Automations.CustomWorker.start(task)
              result = execute(timeout, mix, Map.fetch!(@commands, task), root, timeout_ms)
              Jarvis2.Automations.CustomWorker.finish(worker, result)
              result
            after
              Registry.unregister(Jarvis2.MixRegistry, :run)
            end

          {:error, {:already_registered, _}} ->
            {:error, "another Mix task is running"}
        end
    end
  end

  defp execute(timeout, mix, args, root, timeout_ms) do
    duration = :erlang.float_to_binary(timeout_ms / 1_000, decimals: 3) <> "s"

    try do
      port =
        Port.open({:spawn_executable, timeout}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, root},
          {:args, ["--kill-after=2s", duration, mix | args]}
        ])

      collect(port, [], 0, false, System.monotonic_time(:millisecond) + timeout_ms + 3_000)
    rescue
      _ -> {:error, "unable to start Mix task"}
    end
  end

  defp collect(port, chunks, size, truncated, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        take = min(byte_size(data), @output_limit - size)
        chunks = if take > 0, do: [binary_part(data, 0, take) | chunks], else: chunks

        collect(
          port,
          chunks,
          size + take,
          truncated or take < byte_size(data),
          deadline
        )

      {^port, {:exit_status, status}} ->
        converted = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> safe_utf8([])
        output = cap_utf8(converted)

        {:ok,
         %{
           exit_status: status,
           output: output,
           truncated: truncated or byte_size(output) < byte_size(converted),
           timed_out: status == 124
         }}
    after
      remaining ->
        Port.close(port)
        {:error, "Mix runner timed out"}
    end
  end

  defp cap_utf8(text) when byte_size(text) <= @output_limit, do: text

  defp cap_utf8(text) do
    text
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn part, {acc, size} ->
      if size + byte_size(part) <= @output_limit,
        do: {:cont, {[part | acc], size + byte_size(part)}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp safe_utf8(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) -> IO.iodata_to_binary(Enum.reverse([valid | acc]))
      {:error, valid, <<_bad, rest::binary>>} -> safe_utf8(rest, ["�", valid | acc])
      {:incomplete, valid, _} -> IO.iodata_to_binary(Enum.reverse(["�", valid | acc]))
    end
  end
end

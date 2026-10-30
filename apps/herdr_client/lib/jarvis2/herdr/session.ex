defmodule Jarvis2.Herdr.Session do
  @moduledoc "Ensures a named Herdr session exists without inheriting the calling pane's context."

  @context_env Enum.map(
                 ~w(HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID),
                 &{&1, nil}
               )
  @server_command ~S(nohup "$1" --session "$2" server </dev/null >/dev/null 2>&1 &)

  @doc "Returns the socket path for a running named session, starting it if necessary."
  def ensure(name, opts \\ []) do
    with :ok <- validate_name(name),
         {:ok, executable} <- executable(opts),
         {:ok, session} <- find_session(executable, name) do
      ensure_running(session, executable, name, opts)
    end
  end

  defp ensure_running({:running, path}, _executable, _name, _opts), do: {:ok, path}

  defp ensure_running(:not_running, executable, name, opts) do
    with :ok <- start_server(executable, name) do
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 5_000)
      wait_for_server(executable, name, deadline, Keyword.get(opts, :poll_interval, 100))
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name),
      do: :ok,
      else: {:error, "invalid Herdr session name"}
  end

  defp validate_name(_), do: {:error, "invalid Herdr session name"}

  defp executable(opts) do
    case Keyword.get_lazy(opts, :herdr, fn -> System.find_executable("herdr") end) do
      path when is_binary(path) ->
        if File.regular?(path), do: {:ok, path}, else: {:error, "herdr executable not found"}

      _ ->
        {:error, "herdr executable not found"}
    end
  end

  defp find_session(executable, name) do
    with {:ok, output} <- command(executable, ["session", "list", "--json"]),
         {:ok, %{"sessions" => sessions}} when is_list(sessions) <- Jason.decode(output) do
      case Enum.find(sessions, &(is_map(&1) and &1["name"] == name)) do
        %{"running" => true, "socket_path" => path} when is_binary(path) and path != "" ->
          {:ok, {:running, path}}

        %{"running" => true} ->
          {:error, "running Herdr session has no socket path"}

        _ ->
          {:ok, :not_running}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "invalid Herdr session list response"}
    end
  end

  defp start_server(executable, name) do
    case command("sh", ["-c", @server_command, "sh", executable, name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp wait_for_server(executable, name, deadline, interval) do
    ready =
      with {:ok, {:running, path}} <- find_session(executable, name),
           {:ok, _} <- command(executable, ["--session", name, "api", "snapshot"]) do
        {:ok, path}
      end

    case ready do
      {:ok, path} = result when is_binary(path) ->
        result

      _ ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, "Herdr session #{inspect(name)} did not become ready"}
        else
          Process.sleep(min(interval, remaining))
          wait_for_server(executable, name, deadline, interval)
        end
    end
  end

  defp command(executable, args) do
    case System.cmd(executable, args, env: @context_env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, "Herdr command failed (exit #{status})"}
    end
  rescue
    ErlangError -> {:error, "could not execute Herdr command"}
  end
end

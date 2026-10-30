defmodule Jarvis2.Harness do
  @moduledoc "Installs the board integration in Pi's global MCP configuration."

  @server "jarvis2_board"
  @description "Create Jarvis2 kanban cards for the current working directory."

  def pi_config_path do
    dir = Application.get_env(:jarvis2, :pi_agent_dir) || System.get_env("PI_CODING_AGENT_DIR")
    dir = if dir in [nil, ""], do: "~/.pi/agent", else: dir
    Path.join(Path.expand(dir), "mcp.json")
  end

  def pi_status do
    with {:ok, config, _original, _mode} <- read_config(pi_config_path()) do
      case get_in(config, ["mcpServers", @server]) do
        nil -> {:ok, :missing}
        entry -> {:ok, if(entry == pi_server(), do: :installed, else: :update)}
      end
    end
  end

  def install_pi do
    path = pi_config_path()

    :global.trans({{__MODULE__, path}, self()}, fn -> install_pi_config(path) end)
  end

  defp install_pi_config(path) do
    with {:ok, config, original, mode} <- read_config(path) do
      servers = Map.get(config, "mcpServers", %{})

      if servers[@server] == pi_server() do
        :ok
      else
        updated = Map.put(config, "mcpServers", Map.put(servers, @server, pi_server()))
        write_config(path, original, mode, Jason.encode!(updated, pretty: true) <> "\n")
      end
    end
  end

  defp pi_server do
    %{
      "url" => "http://127.0.0.1:#{Application.get_env(:jarvis2, :port, 4747)}/mcp/board",
      "description" => @description,
      "exposure" => "direct"
    }
  end

  defp read_config(path) do
    with {:ok, original, mode} <- read_original(path),
         {:ok, config} <- decode(original),
         :ok <- check_servers(config) do
      {:ok, config, original, mode}
    end
  end

  defp read_original(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, nil, 0o600}

      {:ok, %{type: :symlink}} ->
        {:error, "The Pi MCP configuration is a symlink; edit its target manually."}

      {:ok, %{type: :regular, mode: mode}} ->
        case File.read(path) do
          {:ok, data} -> {:ok, data, Bitwise.band(mode, 0o777)}
          {:error, _} -> {:error, "Cannot read the Pi MCP configuration."}
        end

      _ ->
        {:error, "Cannot read the Pi MCP configuration."}
    end
  end

  defp decode(nil), do: {:ok, %{}}

  defp decode(original) do
    case original |> String.trim_leading("\uFEFF") |> Jason.decode() do
      {:ok, config} when is_map(config) -> {:ok, config}
      _ -> {:error, "Pi MCP configuration must be a valid JSON object."}
    end
  end

  defp check_servers(config) do
    servers = Map.get(config, "mcpServers", %{})

    cond do
      not is_map(servers) ->
        {:error, "The mcpServers setting must be an object."}

      Map.has_key?(servers, "jarvis2-board") ->
        {:error, "The existing jarvis2-board server conflicts with jarvis2_board."}

      true ->
        :ok
    end
  end

  defp write_config(path, original, mode, content) do
    temp = path <> ".jarvis2-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
      try do
        result =
          with :ok <- File.chmod(temp, mode),
               :ok <- IO.binwrite(file, content),
               :ok <- File.close(file),
               {:ok, ^original, ^mode} <- read_original(path),
               :ok <- File.rename(temp, path) do
            :ok
          else
            {:ok, _, _} -> {:error, "Pi MCP configuration changed; try again."}
            {:error, message} when is_binary(message) -> {:error, message}
            _ -> {:error, "Cannot write the Pi MCP configuration."}
          end

        result
      after
        File.close(file)
        File.rm(temp)
      end
    else
      _ -> {:error, "Cannot write the Pi MCP configuration."}
    end
  end
end

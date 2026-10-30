defmodule Jarvis2.Herdr.Socket do
  @moduledoc """
  Request/response access to the Herdr control socket.

  Herdr serves one request per connection and closes it after replying, so a shared
  connection would fail every other in-flight request (observed with a pending
  `pane.wait_for_output`). Each request therefore uses its own short-lived connection;
  the process only holds the socket path.
  """
  use GenServer

  @connect_timeout 1_000
  @packet_limit 2_097_152
  @request_limit 1_048_576

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def request(method, params, opts \\ []) when is_binary(method) and is_map(params) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 5_000)

    with true <- is_integer(timeout) and timeout > 0,
         {:ok, encoded} <- Jason.encode(%{id: "1", method: method, params: params}),
         :ok <- request_size(encoded) do
      case path(server) do
        {:ok, path} -> exchange(path, encoded, timeout)
        :error -> error("disconnected", "Herdr socket unavailable")
      end
    else
      false -> error("invalid_request", "timeout must be positive")
      {:error, :too_large} -> error("invalid_request", "encoded request exceeds the Herdr limit")
      {:error, _} -> error("invalid_request", "request cannot be encoded as JSON")
    end
  end

  defp request_size(encoded) do
    if byte_size(encoded) + 1 <= @request_limit, do: :ok, else: {:error, :too_large}
  end

  defp path(server) do
    {:ok, GenServer.call(server, :path, 1_000)}
  catch
    :exit, _ -> :error
  end

  defp exchange(path, encoded, timeout) do
    # Line packets otherwise split at the smaller default buffer, before packet_size applies.
    opts = [
      :binary,
      active: false,
      packet: :line,
      packet_size: @packet_limit,
      buffer: @packet_limit + 1
    ]

    case :gen_tcp.connect({:local, path}, 0, opts, @connect_timeout) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, encoded <> "\n"),
               {:ok, line} <- :gen_tcp.recv(socket, 0, timeout) do
            decode(line)
          else
            {:error, :timeout} -> error("timeout", "Herdr request timed out")
            {:error, _} -> error("disconnected", "Herdr socket disconnected")
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        error("disconnected", "Herdr socket unavailable: #{inspect(reason)}")
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => %{"code" => code, "message" => message}}} ->
        {:error, %{code: code, message: message}}

      {:ok, _} ->
        error("invalid_response", "invalid Herdr response")

      {:error, _} ->
        error("disconnected", "Herdr socket disconnected")
    end
  end

  @impl true
  def init(opts) do
    {:ok, Keyword.fetch!(opts, :path)}
  end

  @impl true
  def handle_call(:path, _from, path), do: {:reply, path, path}

  defp error(code, message), do: {:error, %{code: code, message: message}}
end

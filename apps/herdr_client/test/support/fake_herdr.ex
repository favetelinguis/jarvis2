defmodule Jarvis2.Test.FakeHerdr do
  @moduledoc false

  def start_link(path, handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        packet_size: 1_048_576,
        buffer: 1_048_577,
        ifaddr: {:local, path}
      ])

    pid = spawn_link(fn -> accept(listener, handler) end)
    {:ok, pid, listener}
  end

  defp accept(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid =
          spawn(fn ->
            receive do
              :ready -> serve(socket, handler)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :ready)
        accept(listener, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, handler) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        request = Jason.decode!(line)

        case handler.(request) do
          :close ->
            :gen_tcp.close(socket)

          {:reply, response} ->
            case :gen_tcp.send(
                   socket,
                   Jason.encode!(Map.put(response, :id, request["id"])) <> "\n"
                 ) do
              :ok -> serve(socket, handler)
              {:error, _} -> :gen_tcp.close(socket)
            end

          {:later, delay, response} ->
            spawn(fn ->
              Process.sleep(delay)
              :gen_tcp.send(socket, Jason.encode!(Map.put(response, :id, request["id"])) <> "\n")
            end)

            serve(socket, handler)

          {:subscribe, target} ->
            ack =
              Jason.encode!(%{id: request["id"], result: %{type: "subscription_started"}}) <> "\n"

            case :gen_tcp.send(socket, ack) do
              :ok ->
                send(target, {:subscription, socket, request})
                serve(socket, handler)

              {:error, _} ->
                :gen_tcp.close(socket)
            end
        end

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end
end

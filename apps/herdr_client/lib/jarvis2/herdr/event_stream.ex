defmodule Jarvis2.Herdr.EventStream do
  @moduledoc false
  use GenServer

  @connect_timeout 1_000
  @packet_limit 2_097_152

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :connect)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       path: Keyword.fetch!(opts, :path),
       subscriptions: Keyword.fetch!(opts, :subscriptions),
       retry_ms: Keyword.get(opts, :retry_ms, 200),
       socket: nil,
       phase: :connecting,
       attempts: 0,
       timer: nil
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    # Line packets otherwise split at the smaller default buffer, before packet_size applies.
    opts = [
      :binary,
      active: :once,
      packet: :line,
      packet_size: @packet_limit,
      buffer: @packet_limit + 1
    ]

    case :gen_tcp.connect({:local, state.path}, 0, opts, @connect_timeout) do
      {:ok, socket} ->
        request = %{
          id: "subscribe",
          method: "events.subscribe",
          params: %{subscriptions: state.subscriptions}
        }

        case :gen_tcp.send(socket, Jason.encode!(request) <> "\n") do
          :ok ->
            token = make_ref()
            timer = Process.send_after(self(), {:ack_timeout, token}, 3_000)
            {:noreply, %{state | socket: socket, phase: :awaiting, timer: {timer, token}}}

          {:error, _} ->
            :gen_tcp.close(socket)
            {:noreply, retry(state, :send_failed)}
        end

      {:error, _} ->
        {:noreply, retry(state, :connect_failed)}
    end
  end

  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case Jason.decode(line) do
      {:ok, %{"id" => "subscribe", "result" => %{"type" => "subscription_started"}}}
      when state.phase == :awaiting ->
        cancel(state.timer)
        :inet.setopts(socket, active: :once)
        send(state.owner, {:stream_ready, self()})
        {:noreply, %{state | phase: :ready, timer: nil, attempts: 0}}

      {:ok, %{"id" => "subscribe", "error" => %{"code" => "pane_not_found"}}} ->
        send(state.owner, {:stream_missing, self()})
        {:stop, :normal, state}

      {:ok, %{"id" => "subscribe", "error" => %{"code" => code}}} ->
        {:noreply, retry(state, code)}

      {:ok, %{"event" => event, "data" => data}}
      when state.phase == :ready and is_binary(event) and is_map(data) ->
        send(state.owner, {:stream_event, self(), event, data})
        :inet.setopts(socket, active: :once)
        {:noreply, state}

      _ ->
        {:noreply, retry(state, :invalid_response)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, retry(state, :closed)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:noreply, retry(state, reason)}

  def handle_info({:ack_timeout, token}, %{phase: :awaiting, timer: {_, token}} = state),
    do: {:noreply, retry(state, :timeout)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  defp retry(state, reason) do
    cancel(state.timer)
    if state.socket, do: :gen_tcp.close(state.socket)
    send(state.owner, {:stream_down, self(), reason})
    base = min(state.retry_ms * Integer.pow(2, min(state.attempts, 5)), 5_000)
    delay = base + :rand.uniform(max(div(base, 5), 1)) - 1
    Process.send_after(self(), :connect, delay)
    %{state | socket: nil, phase: :connecting, timer: nil, attempts: state.attempts + 1}
  end

  defp cancel(nil), do: :ok
  defp cancel({ref, _token}), do: Process.cancel_timer(ref)
end

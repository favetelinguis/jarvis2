defmodule Jarvis2.LoginCodes do
  @moduledoc """
  Single-use, short-lived codes for signing in to the browser UI. The URL printed at boot carries
  one of these instead of the long-lived API token, so history or logs never leak a reusable secret.
  """
  use GenServer

  @ttl_ms :timer.minutes(10)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Issues a new code valid for ten minutes."
  def issue(server \\ __MODULE__), do: GenServer.call(server, :issue)

  @doc "Consumes a code; returns `:ok` exactly once for a valid, unexpired code."
  def redeem(code, server \\ __MODULE__) when is_binary(code),
    do: GenServer.call(server, {:redeem, code})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:issue, _from, codes) do
    code = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    now = System.monotonic_time(:millisecond)

    codes =
      codes |> Map.reject(fn {_, expires} -> expires <= now end) |> Map.put(code, now + @ttl_ms)

    {:reply, code, codes}
  end

  def handle_call({:redeem, code}, _from, codes) do
    now = System.monotonic_time(:millisecond)

    result =
      Enum.find_value(codes, :error, fn {stored, expires} ->
        if Plug.Crypto.secure_compare(stored, code) and expires > now, do: {:ok, stored}
      end)

    case result do
      {:ok, stored} -> {:reply, :ok, Map.delete(codes, stored)}
      :error -> {:reply, :error, codes}
    end
  end
end

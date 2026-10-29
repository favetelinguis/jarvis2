defmodule Jarvis2.Token do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(:ok) do
    dir = Application.fetch_env!(:jarvis2, :state_dir)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "token")

    token =
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, file} ->
          try do
            # The file is empty until permissions have been restricted.
            File.chmod!(path, 0o600)
            token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
            :ok = IO.binwrite(file, token <> "\n")
            token
          after
            File.close(file)
          end

        {:error, :eexist} ->
          unless File.lstat!(path).type == :regular, do: raise("token must be a regular file")
          File.chmod!(path, 0o600)
          token = path |> File.read!() |> String.trim()
          unless Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, token), do: raise("invalid token file")
          token

        {:error, reason} ->
          raise File.Error, reason: reason, action: "create", path: path
      end

    {:ok, token}
  end

  @impl true
  def handle_call(:get, _from, token), do: {:reply, token, token}
end

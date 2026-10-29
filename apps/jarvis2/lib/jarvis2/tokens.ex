defmodule Jarvis2.Tokens do
  @moduledoc """
  Per-run MCP credentials. A token is minted when a run starts, handed to the agent's pane once,
  and only its SHA-256 hash is stored. Tokens expire and are revoked when the run ends.
  """
  import Ecto.Query

  alias Jarvis2.Repo
  alias Jarvis2.Tokens.ApiToken

  @prefix "j2r_"
  @ttl_s 24 * 3600

  @doc "Returns the plain token; it cannot be recovered later."
  def mint_for_run(run_id, ttl_s \\ @ttl_s) do
    plain = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %ApiToken{
      run_id: run_id,
      token_hash: hash(plain),
      scope: :run,
      expires_at: DateTime.add(DateTime.utc_now(), ttl_s, :second)
    }
    |> Repo.insert!()

    {:ok, plain}
  end

  @doc "The run id behind a valid, unexpired, unrevoked token."
  def resolve(@prefix <> _ = plain) do
    now = DateTime.utc_now()

    query =
      from t in ApiToken,
        where: t.token_hash == ^hash(plain) and is_nil(t.revoked_at) and t.expires_at > ^now,
        select: t.run_id

    case Repo.one(query) do
      nil -> :error
      run_id -> {:ok, run_id}
    end
  end

  def resolve(_other), do: :error

  def revoke_for_run(run_id) do
    Repo.update_all(
      from(t in ApiToken, where: t.run_id == ^run_id and is_nil(t.revoked_at)),
      set: [revoked_at: DateTime.utc_now()]
    )

    :ok
  end

  defp hash(plain), do: :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower)
end

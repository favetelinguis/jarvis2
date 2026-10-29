defmodule Jarvis2.TokensTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Tokens
  alias Jarvis2.Tokens.ApiToken

  test "a minted token resolves to its run and only its hash is stored" do
    run_id = Ecto.UUID.generate()
    {:ok, token} = Tokens.mint_for_run(run_id)

    assert Tokens.resolve(token) == {:ok, run_id}
    [%{token_hash: hash}] = Repo.all(ApiToken)
    refute hash == token
    refute String.contains?(hash, token)
  end

  test "unknown, malformed and foreign-prefix tokens do not resolve" do
    {:ok, token} = Tokens.mint_for_run(Ecto.UUID.generate())

    assert Tokens.resolve(token <> "x") == :error
    assert Tokens.resolve("j2r_nope") == :error
    assert Tokens.resolve("") == :error
    assert Tokens.resolve(Jarvis2.Token.get()) == :error
  end

  test "tokens stop working once revoked or expired" do
    run_id = Ecto.UUID.generate()
    {:ok, revoked} = Tokens.mint_for_run(run_id)
    {:ok, expired} = Tokens.mint_for_run(Ecto.UUID.generate(), -1)
    {:ok, other} = Tokens.mint_for_run(Ecto.UUID.generate())

    assert Tokens.resolve(expired) == :error
    assert Tokens.revoke_for_run(run_id) == :ok
    assert Tokens.resolve(revoked) == :error
    assert {:ok, _} = Tokens.resolve(other)
  end
end

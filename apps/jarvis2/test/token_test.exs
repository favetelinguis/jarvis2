defmodule Jarvis2.TokenTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env!(:jarvis2, :state_dir)
    dir = Path.join(previous, "token-test-#{System.unique_integer([:positive])}")
    Application.put_env(:jarvis2, :state_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :state_dir, previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "reuses an existing token rather than changing it", %{dir: dir} do
    assert {:ok, first} = Jarvis2.Token.init(:ok)
    assert {:ok, ^first} = Jarvis2.Token.init(:ok)
    assert File.read!(Path.join(dir, "token")) == first <> "\n"
  end

  test "refuses a symlink in place of the token", %{dir: dir} do
    File.mkdir_p!(dir)
    File.ln_s!(Path.join(dir, "elsewhere"), Path.join(dir, "token"))
    assert_raise RuntimeError, "token must be a regular file", fn -> Jarvis2.Token.init(:ok) end
    refute File.exists?(Path.join(dir, "elsewhere"))
  end
end

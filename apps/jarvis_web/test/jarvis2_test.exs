defmodule Jarvis2Test do
  use ExUnit.Case
  doctest Jarvis2

  test "greets the world" do
    assert Jarvis2.hello() == :world
  end
end

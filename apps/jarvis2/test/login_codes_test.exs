defmodule Jarvis2.LoginCodesTest do
  use ExUnit.Case, async: true

  alias Jarvis2.LoginCodes

  setup do
    %{codes: start_supervised!({LoginCodes, name: nil}, id: make_ref())}
  end

  test "a code works exactly once", %{codes: codes} do
    code = LoginCodes.issue(codes)
    assert LoginCodes.redeem(code, codes) == :ok
    assert LoginCodes.redeem(code, codes) == :error
  end

  test "unknown codes are refused and do not consume valid ones", %{codes: codes} do
    code = LoginCodes.issue(codes)
    assert LoginCodes.redeem("wrong", codes) == :error
    assert LoginCodes.redeem(code, codes) == :ok
  end
end

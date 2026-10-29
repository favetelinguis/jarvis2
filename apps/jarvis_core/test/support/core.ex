defmodule Jarvis2.Test.Core do
  @moduledoc false

  def start do
    if Process.whereis(Jarvis2.Supervisor) == nil do
      dir = Application.fetch_env!(:jarvis2, :state_dir)
      File.mkdir_p!(dir)
      {:ok, _} = Supervisor.start_link(Jarvis2.Core.child_specs(), strategy: :rest_for_one)
      ExUnit.after_suite(fn _ -> File.rm_rf!(dir) end)
    end
  end
end

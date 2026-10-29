defmodule Jarvis2.Scenarios do
  @moduledoc false

  def child_specs do
    [
      Jarvis2.Scenarios.OutputWatcher,
      Jarvis2.Scenarios.Attention,
      Jarvis2.Scenarios.Restore,
      Jarvis2.Scenarios.Presentation,
      Jarvis2.Scenarios.TestLoop
    ]
  end
end

defmodule Jarvis2.Automations do
  @moduledoc false

  def child_specs do
    [
      Jarvis2.Automations.OutputWatcher,
      Jarvis2.Automations.Attention,
      Jarvis2.Automations.Presentation,
      Jarvis2.Automations.TestLoop
    ]
  end
end

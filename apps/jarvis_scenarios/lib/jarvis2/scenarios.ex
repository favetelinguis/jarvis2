defmodule Jarvis2.Scenarios do
  @moduledoc false

  def child_specs do
    [
      Jarvis2.Scenarios.OutputWatcher,
      Jarvis2.Scenarios.Attention,
      Jarvis2.Scenarios.Restore,
      Jarvis2.Scenarios.FocusMode,
      Jarvis2.Scenarios.LayoutDev,
      Jarvis2.Scenarios.Dashboard,
      Jarvis2.Scenarios.Presentation,
      Jarvis2.Scenarios.SendToAgent,
      Jarvis2.Scenarios.DocsLink,
      Jarvis2.Scenarios.WorktreeTask,
      Jarvis2.Scenarios.ReviewDiff,
      Jarvis2.Scenarios.TestLoop
    ]
  end
end

defmodule Jarvis2.Core do
  @moduledoc false

  def child_specs do
    [
      {Registry, keys: :duplicate, name: Jarvis2.Registry},
      Supervisor.child_spec({Registry, keys: :unique, name: Jarvis2.MixRegistry},
        id: Jarvis2.MixRegistry
      ),
      Jarvis2.State,
      Jarvis2.Token,
      Jarvis2.Herdr.Socket,
      {Task.Supervisor, name: Jarvis2.TaskSupervisor},
      Jarvis2.Herdr.Mirror,
      Jarvis2.Herdr.PromptGuard,
      Jarvis2.Herdr.ExecutionGuard
    ]
  end
end

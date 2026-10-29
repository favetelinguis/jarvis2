defmodule Jarvis2Web.InboxCount do
  @moduledoc "`on_mount` hook keeping the navigation's inbox badge current on every page."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Jarvis2.Questions

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, Questions.inbox_topic())

    socket =
      socket
      |> assign(:inbox_count, Questions.pending_count())
      |> attach_hook(:inbox_count, :handle_info, fn
        :inbox_changed, socket ->
          {:halt, assign(socket, :inbox_count, Questions.pending_count())}

        _other, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end

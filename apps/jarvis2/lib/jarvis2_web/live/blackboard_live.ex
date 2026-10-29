defmodule Jarvis2Web.BlackboardLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.Blackboard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, Blackboard.topic())
    {:ok, socket |> assign(:form, to_form(%{"key" => "", "value" => ""}, as: :entry)) |> load()}
  end

  @impl true
  def handle_event("save", %{"entry" => %{"key" => key, "value" => text}}, socket) do
    with {:ok, value} <- decode(text),
         :ok <- put(String.trim(key), value) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved #{String.trim(key)}.")
       |> assign(:form, to_form(%{"key" => "", "value" => ""}, as: :entry))}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("edit", %{"key" => key}, socket) do
    value = key |> Blackboard.get() |> elem_or_nil() |> Jason.encode!(pretty: true)
    {:noreply, assign(socket, :form, to_form(%{"key" => key, "value" => value}, as: :entry))}
  end

  def handle_event("delete", %{"key" => key}, socket) do
    Blackboard.delete(key)
    {:noreply, put_flash(socket, :info, "Deleted #{key}.")}
  end

  @impl true
  def handle_info(:blackboard_changed, socket), do: {:noreply, load(socket)}

  defp put(key, value) do
    case Blackboard.put(key, value) do
      :ok -> :ok
      {:error, :full} -> {:error, "The blackboard is full (256 keys)."}
      {:error, :invalid} -> {:error, "Invalid key (1–256 bytes) or value too large (16 KiB)."}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "The value must be valid JSON, for example \"text\" or {\"a\": 1}."}
    end
  end

  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(:error), do: nil

  defp load(socket) do
    entries = Blackboard.list_entries()

    runs =
      Map.new(
        entries,
        &{&1.updated_by_run_id,
         &1.updated_by_run_id && Jarvis2.Runs.get_run(&1.updated_by_run_id)}
      )

    assign(socket, entries: entries, runs: runs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Blackboard</h1>
    <p class="muted">Notes shared between agents and you. Values are JSON.</p>

    <.form for={@form} id="entry-form" phx-submit="save" class="stack">
      <label>
        Key <input type="text" name="entry[key]" value={@form[:key].value} required />
      </label>
      <label>
        Value (JSON) <textarea name="entry[value]" rows="4" required>{@form[:value].value}</textarea>
      </label>
      <button type="submit">Save</button>
    </.form>

    <table>
      <thead>
        <tr>
          <th>Key</th><th>Value</th><th>Updated</th><th>By</th><th></th>
        </tr>
      </thead>
      <tbody>
        <tr :for={entry <- @entries} id={"entry-#{entry.id}"}>
          <td><code>{entry.key}</code></td>
          <td><pre class="payload">{Jason.encode!(entry.value, pretty: true)}</pre></td>
          <td>{Calendar.strftime(entry.updated_at, "%Y-%m-%d %H:%M:%S")}</td>
          <td>
            <% run = @runs[entry.updated_by_run_id] %>
            <.link :if={run} navigate={"/runs/#{run.id}"}>{run.name}</.link>
            <span :if={!run} class="muted">{if entry.updated_by_run_id, do: "gone", else: "—"}</span>
          </td>
          <td class="actions">
            <button phx-click="edit" phx-value-key={entry.key}>Edit</button>
            <button phx-click="delete" phx-value-key={entry.key} data-confirm="Delete this entry?">
              Delete
            </button>
          </td>
        </tr>
      </tbody>
    </table>
    <p :if={@entries == []} class="muted">The blackboard is empty.</p>
    """
  end
end

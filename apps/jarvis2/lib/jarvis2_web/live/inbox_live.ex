defmodule Jarvis2Web.InboxLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Questions, Runs}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, Questions.topic())
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("answer", params, socket),
    do: {:noreply, Jarvis2Web.QuestionActions.answer(socket, params)}

  @impl true
  def handle_info({:question, _question}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    questions = Questions.list_pending()
    runs = Map.new(questions, &{&1.run_id, Runs.get_run(&1.run_id)})
    assign(socket, questions: questions, runs: runs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Inbox</h1>
    <p :if={@questions == []} class="muted">Nothing is waiting for you.</p>
    <.question_card :for={question <- @questions} question={question} run={@runs[question.run_id]} />
    """
  end
end

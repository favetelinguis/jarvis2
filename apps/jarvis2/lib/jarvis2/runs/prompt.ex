defmodule Jarvis2.Runs.Prompt do
  @moduledoc "The first message a run's agent receives: how to reach the human, then the task."

  def build(run) do
    """
    You are running as Jarvis2 run "#{run.name}". Jarvis2's MCP server (`jarvis2`) is available:
    - report_status(state, summary): tell the human what you are doing (working, blocked or done).
    - ask_human(prompt, options?): ask a question. It returns a ticket; call wait_for_answer(ticket)
      repeatedly until the status is no longer "pending".
    - request_approval(action, detail): get approval before any risky or irreversible action. Same
      ticket flow; the answer is "approve" or "deny". Do not proceed unless it is "approve".
    - submit_result(summary, artifacts?): call this once when the task is complete.

    Task:
    #{run.task}
    """
    |> String.trim()
  end
end

defmodule Jarvis2.Subagents.Prompt do
  @moduledoc false

  def build(role, task) do
    role.prompt <>
      "\n\n## Working as a subagent\n" <>
      "Review the spawner's checkout. Do not edit, commit, or push. Do not ask the human; " <>
      "report blockers to the spawner. Submit your report with submit_result and end your turn.\n\n" <>
      "## Review task\n" <> task
  end

  def result(run) do
    summary =
      run.result["summary"] |> String.replace("</subagent_result>", "&lt;/subagent_result>")

    "<subagent_result id=\"#{run.id}\" role=\"#{run.role}\" status=\"finished\">\n" <>
      summary <> "\n</subagent_result>"
  end
end

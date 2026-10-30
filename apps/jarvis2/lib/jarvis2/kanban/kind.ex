defmodule Jarvis2.Kanban.Kind do
  @moduledoc false

  @implementation %{
    name: :implementation,
    noun: "implementation report",
    max_deliverable: 20_000,
    advance: nil,
    role: "implementer"
  }

  @kinds %{
    plan: %{
      label: "Plan",
      hint: "Describe your idea",
      max_questions: 8,
      max_body: 2_000,
      stages: [
        %{
          name: :planning,
          noun: "plan",
          advance: %{to: :implementation, label: "Accept plan"},
          max_deliverable: 20_000,
          role: "planner"
        },
        @implementation
      ]
    },
    research: %{
      label: "Research",
      hint: "Enter a question or topic",
      max_questions: 4,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "report",
          advance: nil,
          max_deliverable: 20_000,
          role: "researcher"
        }
      ]
    },
    explain: %{
      label: "Explain",
      hint: "Enter a diff, commit range, branch or PR link",
      max_questions: 2,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "explanation",
          advance: nil,
          max_deliverable: 20_000,
          role: "explainer"
        }
      ]
    },
    review: %{
      label: "Review",
      hint: "Enter a PR link or number, branch or commit range",
      max_questions: 3,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "review",
          advance: nil,
          max_deliverable: 20_000,
          role: "reviewer"
        }
      ]
    },
    slides: %{
      label: "Slides",
      hint: "Topic or question to present; say 'this repo' to cover the working directory",
      max_questions: 4,
      max_body: 4_000,
      deliverable: :html,
      stages: [
        %{
          name: :main,
          noun: "slide deck",
          advance: nil,
          max_deliverable: 200_000,
          role: "slide-maker"
        }
      ]
    },
    architecture: %{
      label: "Architecture",
      hint: "Name a module, subsystem or pain point, or leave open to scan the hot spots",
      max_questions: 3,
      max_body: 4_000,
      deliverable: :html,
      stages: [
        %{
          name: :main,
          noun: "architecture report",
          advance: nil,
          max_deliverable: 200_000,
          role: "architect"
        }
      ]
    },
    agents_file: %{
      label: "Agents file",
      hint: "Leave blank to audit and refresh, or say what to change",
      max_questions: 3,
      max_body: 4_000,
      deliverable: :agents_file,
      stages: [
        %{
          name: :main,
          noun: "agents file proposal",
          advance: nil,
          max_deliverable: 60_000,
          role: "agents-file-writer"
        }
      ]
    },
    arrange: %{
      label: "Arrange",
      hint: "Created from the graph page",
      max_questions: 4,
      max_body: 4_000,
      deliverable: :edges,
      stages: [
        %{
          name: :main,
          noun: "dependency proposals",
          advance: nil,
          max_deliverable: 60_000,
          role: "arranger"
        }
      ]
    },
    refine: %{
      label: "Refine",
      hint: "Paste the Jira ticket text",
      max_questions: 4,
      max_body: 4_000,
      stages: [
        %{
          name: :main,
          noun: "refined ticket",
          advance: nil,
          max_deliverable: 4_000,
          role: "refiner"
        }
      ]
    }
  }

  def all,
    do: [
      :plan,
      :research,
      :explain,
      :review,
      :refine,
      :slides,
      :architecture,
      :arrange,
      :agents_file
    ]

  def creatable, do: all() -- [:arrange]
  def get(kind), do: Map.fetch!(@kinds, kind)
  def deliverable_type(kind), do: Map.get(get(kind), :deliverable, :markdown)
  def stages(kind), do: get(kind).stages
  def initial_stage(kind), do: hd(stages(kind)).name
  def stage(kind, name), do: Enum.find(stages(kind), &(&1.name == name))
  def noun(kind), do: noun(kind, initial_stage(kind))
  def noun(kind, name), do: stage(kind, name).noun

  @human_protocol """
  ## Working with the human

  The human does not read your terminal output; only Jarvis2 MCP tool calls reach them. Keep chat output minimal.
  Ask only with `ask_questions`, then end your turn; the answers arrive as your next message.
  Finish only with `submit_deliverable`. Find facts yourself; never guess decisions, ask.
  Whenever you load a skill, call `report_skill` with its name and why you loaded it.
  When the card is about the project in the working directory, read GLOSSARY.md and docs/adr/ if they exist. Use the glossary's terms exactly in everything you write, and say so at once when a term or the code conflicts with it or an ADR.
  """

  @doc "The role prompt followed by the instructions every kanban role shares."
  def protocol(_kind, _name, prompt),
    do: String.trim(prompt) <> "\n\n" <> String.trim(@human_protocol)
end

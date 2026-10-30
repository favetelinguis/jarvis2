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

  def all, do: [:plan, :research, :explain, :review, :refine, :slides]
  def get(kind), do: Map.fetch!(@kinds, kind)
  def deliverable_type(kind), do: Map.get(get(kind), :deliverable, :markdown)
  def stages(kind), do: get(kind).stages
  def initial_stage(kind), do: hd(stages(kind)).name
  def stage(kind, name), do: Enum.find(stages(kind), &(&1.name == name))
  def noun(kind), do: noun(kind, initial_stage(kind))
  def noun(kind, name), do: stage(kind, name).noun

  def protocol(_kind, _name, prompt), do: String.trim(prompt)
end

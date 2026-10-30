defmodule Jarvis2.AgentsFileTest do
  use ExUnit.Case, async: true

  alias Jarvis2.Kanban.{AgentsFile, Card}
  alias Jarvis2.Runs.Run

  setup do
    dir = Path.join(System.tmp_dir!(), "agents-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp proposal(content, changes \\ []) do
    Jason.encode!(%{content: content, changes: changes})
  end

  defp card(dir, content) do
    {:ok, base} = AgentsFile.fingerprint(dir)

    %Card{
      kind: :agents_file,
      column: :done,
      run: %Run{cwd: dir},
      agents_file_base: base,
      deliverable: proposal(content)
    }
  end

  test "validates JSON, content, size and change entries" do
    assert :ok = AgentsFile.validate(proposal("# Instructions\n"))

    for invalid <- [
          "{",
          proposal(" "),
          proposal(String.duplicate("x", 32_769)),
          proposal("x", [%{action: "remove", section: "s", reason: "", source: "AGENTS.md"}]),
          proposal(
            "x",
            List.duplicate(
              %{action: "remove", section: "s", reason: "x", source: "AGENTS.md"},
              101
            )
          )
        ] do
      assert {:error, _} = AgentsFile.validate(invalid)
    end
  end

  test "review computes the actual diff and apply keeps CLAUDE.md untouched", %{dir: dir} do
    File.write!(Path.join(dir, "CLAUDE.md"), "other\n")
    card = card(dir, "new\n")
    assert {:ok, %{status: :create, added_lines: 1, removed_lines: 0}} = AgentsFile.review(card)
    assert :ok = AgentsFile.apply!(card)
    assert File.read!(Path.join(dir, "AGENTS.md")) == "new\n"
    assert File.read!(Path.join(dir, "CLAUDE.md")) == "other\n"
    assert {:ok, %{status: :unchanged}} = AgentsFile.review(card(dir, "new\n"))
    assert {:ok, review} = AgentsFile.review(card(dir, "replacement\n"))
    assert review.status == :update
    assert review.removed_lines == 1 and review.added_lines == 1
    assert {:del, ["new\n"]} in review.diff
  end

  test "never overwrites CLAUDE.md through an AGENTS.md symlink", %{dir: dir} do
    File.write!(Path.join(dir, "CLAUDE.md"), "original")
    File.ln_s!("CLAUDE.md", Path.join(dir, "AGENTS.md"))
    card = card(dir, "new")
    assert {:error, message} = AgentsFile.apply!(card)
    assert message =~ "CLAUDE.md"
    assert File.read!(Path.join(dir, "CLAUDE.md")) == "original"
  end

  test "rejects drift and escaping symlinks, writes an internal symlink target", %{dir: dir} do
    File.write!(Path.join(dir, "target"), "old")
    File.ln_s!("target", Path.join(dir, "AGENTS.md"))
    card = card(dir, "new")
    assert :ok = AgentsFile.apply!(card)
    assert File.read!(Path.join(dir, "target")) == "new"
    assert {:ok, "target"} = File.read_link(Path.join(dir, "AGENTS.md"))
    assert {:error, _} = AgentsFile.apply!(card)
    File.rm!(Path.join(dir, "AGENTS.md"))
    File.ln_s!("../outside", Path.join(dir, "AGENTS.md"))
    assert {:error, _} = AgentsFile.fingerprint(dir)
  end
end

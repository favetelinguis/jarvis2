defmodule Jarvis2.RolesTest do
  use ExUnit.Case, async: false

  alias Jarvis2.{Roles, StepRoles}

  setup do
    dir = Path.join(System.tmp_dir!(), "jarvis2-roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.fetch_env!(:jarvis2, :roles_dir)
    Application.put_env(:jarvis2, :roles_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :roles_dir, previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "parses frontmatter and long body", %{dir: dir} do
    body = String.duplicate("é", 3_000)

    File.write!(
      Path.join(dir, "planner.md"),
      "---\nname: planner\ndescription: 'A: description'\n---\n#{body}"
    )

    File.write!(Path.join(dir, "ignored.txt"), "ignored")
    assert [{:ok, role}] = Roles.list()
    assert role.description == "A: description"
    assert role.model == nil and role.effort == nil
    assert role.prompt == body
  end

  test "reports invalid files without crashing", %{dir: dir} do
    for {file, content} <- [
          {"wrong.md", "---\nname: other\n---\nbody"},
          {"bad_name.md", "---\nname: bad_name\n---\nbody"},
          {"model.md", "---\nname: model\nmodel: foo/bar;bad\n---\nbody"},
          {"effort.md", "---\nname: effort\neffort: extreme\n---\nbody"},
          {"empty.md", "---\nname: empty\n---\n "},
          {"missing.md", "no header"},
          {"yaml.md", "---\nname: [\n---\nbody"},
          {"map.md", "---\n- foo\n---\nbody"},
          {"utf8.md", <<"---\nname: utf8\n---\n", 255>>}
        ] do
      File.write!(Path.join(dir, file), content)
    end

    assert length(Roles.list()) == 9
    assert Enum.all?(Roles.list(), &match?({:error, %{file: _, reason: _}}, &1))
    assert {:error, message} = Roles.get("wrong")
    assert message =~ "wrong"
  end

  test "shipped roles cover all defaults" do
    Application.put_env(:jarvis2, :roles_dir, Path.expand("../../../roles", __DIR__))
    assert Enum.all?(Roles.list(), &match?({:ok, _}, &1))

    for {kind, stage} <- StepRoles.steps() do
      assert {:ok, role} = Roles.get(Jarvis2.Kanban.Kind.stage(kind, stage).role)
      refute role.prompt =~ "## Working with the human"

      protocol = Jarvis2.Kanban.Kind.protocol(kind, stage, role.prompt)
      assert String.starts_with?(protocol, role.prompt)
      assert protocol =~ "## Working with the human"
      assert protocol =~ "ask_questions"
      assert protocol =~ "submit_deliverable"
      assert protocol =~ "call `report_skill` with its name and why you loaded it"
    end

    for name <- ~w(researcher explainer reviewer slide-maker refiner architect) do
      assert {:ok, role} = Roles.get(name)
      assert role.prompt =~ "Do not edit files, commit, push, or comment on or approve a PR."
    end
  end

  test "every skill is valid and every skill a role loads exists" do
    Application.put_env(:jarvis2, :roles_dir, Path.expand("../../../roles", __DIR__))
    skills_dir = Path.expand("../../../skills", __DIR__)

    skills =
      for dir <- File.ls!(skills_dir), File.dir?(Path.join(skills_dir, dir)) do
        text = File.read!(Path.join([skills_dir, dir, "SKILL.md"]))
        assert text =~ "name: #{dir}\n"
        assert text =~ ~r/^description: \S/m
        dir
      end

    for {:ok, role} <- Roles.list() do
      [_, section] = String.split(role.prompt, "## Skills\n", parts: 2)
      section = section |> String.split("\n## ", parts: 2) |> hd()

      named =
        Regex.scan(~r/`([a-z0-9]+(?:-[a-z0-9]+)*)`/, section)
        |> Enum.map(&List.last/1)
        |> Enum.uniq()

      assert named != [], "#{role.name} loads no skill"
      assert named -- skills == [], "#{role.name} names a missing skill"
    end
  end

  test "the architecture report template satisfies the HTML contract" do
    template =
      Path.expand(
        "../../../skills/improve-codebase-architecture/references/template.html",
        __DIR__
      )

    assert :ok = Jarvis2.Kanban.Slides.validate(File.read!(template))
  end

  test "the slide template satisfies the deck contract" do
    template = Path.expand("../../../skills/slide-deck/references/template.html", __DIR__)
    assert :ok = Jarvis2.Kanban.Slides.validate(File.read!(template))
  end
end

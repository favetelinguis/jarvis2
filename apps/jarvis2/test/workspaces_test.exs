defmodule Jarvis2.WorkspacesTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Herdr.Workspaces

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _, view), do: {:reply, view, view}
    def handle_cast(:invalidate, view), do: {:noreply, view}
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "j2-workspaces-#{System.unique_integer([:positive])}.sock")

    {:ok, responses} = start_supervised({Agent, fn -> %{} end})
    parent = self()

    handler = fn request ->
      send(parent, {:request, request["method"], request["params"]})
      response = Agent.get(responses, &Map.fetch!(&1, request["method"]))
      {:reply, response}
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [name: nil, path: path]})
    old_socket = Application.fetch_env(:jarvis2, :herdr_socket)
    Application.put_env(:jarvis2, :herdr_socket, socket)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)

      case old_socket do
        {:ok, value} -> Application.put_env(:jarvis2, :herdr_socket, value)
        :error -> Application.delete_env(:jarvis2, :herdr_socket)
      end
    end)

    %{responses: responses}
  end

  defp set(ctx, method, response), do: Agent.update(ctx.responses, &Map.put(&1, method, response))
  defp list(trees), do: %{result: %{type: "worktree_list", worktrees: trees}}

  defp main(open \\ nil),
    do: %{path: "/repo", branch: "master", is_linked_worktree: false, open_workspace_id: open}

  defp linked(open \\ nil),
    do: %{path: "/linked", branch: "feature/x", is_linked_worktree: true, open_workspace_id: open}

  defp created(id, path),
    do: %{
      result: %{
        workspace: %{workspace_id: id},
        tab: %{tab_id: id <> ":t1"},
        worktree: %{path: path}
      }
    }

  test "main resolves the non-linked checkout, even from inside a linked worktree", ctx do
    set(ctx, "worktree.list", list([main("w1"), linked("w2")]))

    assert {:ok, %{workspace_id: "w1", checkout_path: "/repo", fresh_tab_ids: []}} =
             Workspaces.resolve("/linked/sub", "main")

    assert_receive {:request, "worktree.list", %{"cwd" => "/linked/sub"}}
    refute_receive {:request, "worktree.open", _}, 30

    assert {:ok, [%{main?: true}, %{branch: "feature/x", open?: true}]} =
             Workspaces.list_worktrees("/repo")
  end

  test "opens a missing root using its path", ctx do
    set(ctx, "worktree.list", list([main()]))
    set(ctx, "worktree.open", created("w1", "/repo"))

    assert {:ok, %{workspace_id: "w1", checkout_path: "/repo", fresh_tab_ids: ["w1:t1"]}} =
             Workspaces.resolve("/linked/sub", "main")

    assert_receive {:request, "worktree.open",
                    %{"cwd" => "/repo", "path" => "/repo", "focus" => false}}
  end

  test "reuses an open linked worktree", ctx do
    set(ctx, "worktree.list", list([main("w1"), linked("w2")]))

    assert {:ok, %{workspace_id: "w2", checkout_path: "/linked", fresh_tab_ids: []}} =
             Workspaces.resolve("/repo", "feature/x")

    refute_receive {:request, "worktree.open", _}, 30
  end

  test "opens existing and creates new worktrees under root", ctx do
    set(ctx, "worktree.list", list([main("w1"), linked()]))
    set(ctx, "worktree.open", created("w2", "/linked"))

    assert {:ok, %{workspace_id: "w2", fresh_tab_ids: ["w2:t1"]}} =
             Workspaces.resolve("/repo", "feature/x")

    assert_receive {:request, "worktree.open",
                    %{"workspace_id" => "w1", "branch" => "feature/x", "focus" => false}}

    set(ctx, "worktree.list", list([main("w1")]))
    set(ctx, "worktree.create", created("w3", "/new"))

    assert {:ok, %{workspace_id: "w3", checkout_path: "/new"}} =
             Workspaces.resolve("/repo", "new")

    assert_receive {:request, "worktree.create", params}
    assert params == %{"workspace_id" => "w1", "branch" => "new", "focus" => false}
  end

  test "uncertain creation warns and retry re-reads the list", ctx do
    set(ctx, "worktree.list", list([main("w1")]))
    set(ctx, "worktree.create", %{error: %{code: "timeout", message: "timeout"}})
    assert {:error, message} = Workspaces.resolve("/repo", "feature/x")
    assert message =~ "inspect" and message =~ "may have been created"
    assert_receive {:request, "worktree.create", _}
    set(ctx, "worktree.list", list([main("w1"), linked()]))
    set(ctx, "worktree.open", created("w2", "/linked"))
    assert {:ok, _} = Workspaces.resolve("/repo", "feature/x")
    assert_receive {:request, "worktree.open", _}
    refute_receive {:request, "worktree.create", _}, 30
  end

  test "non-git directories and Herdr errors", ctx do
    set(ctx, "worktree.list", %{error: %{code: "not_git_worktree", message: "not git"}})
    set(ctx, "workspace.create", created("w4", "/plain"))
    assert {:error, message} = Workspaces.resolve("/plain", "branch")
    assert message =~ "Git"

    assert {:ok, %{workspace_id: "w4", checkout_path: "/plain", fresh_tab_ids: ["w4:t1"]}} =
             Workspaces.resolve("/plain", "main")

    assert_receive {:request, "workspace.create", %{"cwd" => "/plain", "focus" => false}}

    set(ctx, "worktree.list", %{
      error: %{
        code: "worktree_list_failed",
        message: "fatal: detected dubious ownership in repository"
      }
    })

    assert {:error, message} = Workspaces.resolve("/plain", "main")
    assert message =~ "untrusted" and message =~ "worktree_list_failed"
  end

  test "reuses a non-git workspace with a matching pane", ctx do
    set(ctx, "worktree.list", %{error: %{code: "not_git_worktree", message: "not git"}})

    mirror =
      start_supervised!(
        {Mirror,
         %{
           stale: false,
           snapshot: %{
             "panes" => [
               %{"cwd" => "/plain", "foreground_cwd" => "/elsewhere", "workspace_id" => "w9"}
             ]
           }
         }}
      )

    old = Application.fetch_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, mirror)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:jarvis2, :mirror, value)
        :error -> Application.delete_env(:jarvis2, :mirror)
      end
    end)

    assert {:ok, %{workspace_id: "w9", checkout_path: "/plain", fresh_tab_ids: []}} =
             Workspaces.resolve("/plain", "main")

    refute_receive {:request, "workspace.create", _}, 30
  end

  test "a new root is retained when creating a linked workspace", ctx do
    set(ctx, "worktree.list", list([main()]))
    set(ctx, "worktree.open", created("w1", "/repo"))
    set(ctx, "worktree.create", created("w2", "/linked"))

    assert {:ok, %{workspace_id: "w2", fresh_tab_ids: ["w2:t1"]}} =
             Workspaces.resolve("/repo", "feature/x")

    assert_receive {:request, "worktree.open", %{"path" => "/repo"}}
    assert_receive {:request, "worktree.create", %{"workspace_id" => "w1"}}
  end

  test "rejects invalid branch names before contacting Herdr", _ctx do
    for bad <- ["-x", "a..b", "a b", "x/", "x.lock", String.duplicate("a", 101), ""] do
      assert {:error, _} = Workspaces.resolve("/repo", bad)
    end

    refute_receive {:request, _, _}, 30
  end
end

defmodule Jarvis2.Herdr.Workspaces do
  @moduledoc "Resolves a project and worktree to a Herdr workspace."

  alias Jarvis2.Herdr.{Mirror, Socket}

  def valid_worktree?(value) when is_binary(value) do
    Regex.match?(~r|\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z|, value) and
      not String.contains?(value, "..") and not String.ends_with?(value, ["/", ".lock"])
  end

  def valid_worktree?(_), do: false

  def list_worktrees(cwd) do
    case list(cwd) do
      {:ok, trees} ->
        {:ok,
         Enum.map(trees, fn tree ->
           %{
             branch: tree["branch"],
             path: tree["path"],
             open?: is_binary(tree["open_workspace_id"]),
             main?: tree["is_linked_worktree"] == false
           }
         end)}

      {:error, %{code: "not_git_worktree"}} ->
        {:ok, []}

      {:error, error} ->
        {:error, error_message(error)}
    end
  end

  def resolve(cwd, worktree) do
    if valid_worktree?(worktree) do
      case list(cwd) do
        {:ok, trees} -> resolve_git(cwd, worktree, trees)
        {:error, %{code: "not_git_worktree"}} -> resolve_non_git(cwd, worktree)
        {:error, error} -> {:error, error_message(error)}
      end
    else
      {:error, "Invalid worktree branch name."}
    end
  end

  defp list(cwd) do
    case request("worktree.list", %{cwd: cwd}) do
      {:ok, %{"worktrees" => trees}} when is_list(trees) ->
        if Enum.all?(
             trees,
             &(is_map(&1) and is_binary(&1["path"]) and is_boolean(&1["is_linked_worktree"]))
           ) do
          {:ok, trees}
        else
          {:error, %{code: "invalid_response"}}
        end

      {:ok, _} ->
        {:error, %{code: "invalid_response"}}

      error ->
        error
    end
  end

  defp resolve_git(cwd, worktree, trees) do
    case Enum.find(trees, &(&1["is_linked_worktree"] == false and is_binary(&1["path"]))) do
      nil ->
        {:error, "Herdr did not report a main checkout (invalid_response)."}

      main ->
        target =
          Enum.find(trees, &(&1["is_linked_worktree"] == true and &1["branch"] == worktree))

        with {:ok, root} <- ensure_root(cwd, main), do: resolve_target(root, target, worktree)
    end
  end

  defp ensure_root(_cwd, %{"open_workspace_id" => id, "path" => path})
       when is_binary(id) and id != "" do
    {:ok, %{workspace_id: id, checkout_path: path, fresh_tab_ids: []}}
  end

  defp ensure_root(_cwd, %{"path" => path}) do
    # Herdr rejects a linked worktree as the source for opening the repository root.
    mutate("worktree.open", %{cwd: path, path: path, focus: false}, path)
  end

  defp resolve_target(root, _target, "main"), do: {:ok, root}

  defp resolve_target(_root, %{"open_workspace_id" => id, "path" => path}, _branch)
       when is_binary(id) and id != "" and is_binary(path) do
    # The newly opened root has no card tab of its own; closing its last tab closes the workspace.
    {:ok, %{workspace_id: id, checkout_path: path, fresh_tab_ids: []}}
  end

  defp resolve_target(root, target, branch) do
    method = if target, do: "worktree.open", else: "worktree.create"
    path = if target, do: target["path"], else: nil

    mutate(method, %{workspace_id: root.workspace_id, branch: branch, focus: false}, path)
  end

  defp resolve_non_git(_cwd, worktree) when worktree != "main",
    do: {:error, "A linked worktree requires a Git repository."}

  defp resolve_non_git(cwd, "main") do
    view =
      try do
        Mirror.get(mirror())
      catch
        :exit, _ -> nil
      end

    pane =
      case view do
        %{stale: false, snapshot: %{"panes" => panes}} when is_list(panes) ->
          Enum.find(
            panes,
            &((&1["foreground_cwd"] == cwd or &1["cwd"] == cwd) and is_binary(&1["workspace_id"]))
          )

        _ ->
          nil
      end

    if pane do
      {:ok, %{workspace_id: pane["workspace_id"], checkout_path: cwd, fresh_tab_ids: []}}
    else
      mutate("workspace.create", %{cwd: cwd, focus: false}, cwd)
    end
  end

  defp mutate(method, params, fallback_path) do
    result = request(method, params)
    Mirror.invalidate(mirror())

    case result do
      {:ok, reply} ->
        mutation_result(reply, fallback_path)

      {:error, %{code: code} = error} when code not in ["timeout", "disconnected"] ->
        {:error, mutation_error(error)}

      _ ->
        {:error, "A worktree may have been created; inspect the session before retrying."}
    end
  end

  defp mutation_result(
         %{"workspace" => %{"workspace_id" => id}, "tab" => %{"tab_id" => tab}} = reply,
         fallback
       )
       when is_binary(id) and id != "" and is_binary(tab) and tab != "" do
    path = get_in(reply, ["worktree", "path"]) || fallback

    if is_binary(path) and path != "" do
      fresh = if reply["already_open"] == true, do: [], else: [tab]
      {:ok, %{workspace_id: id, checkout_path: path, fresh_tab_ids: fresh}}
    else
      {:error, "A workspace may have been created; inspect the session before retrying."}
    end
  end

  defp mutation_result(_, _),
    do: {:error, "A workspace may have been created; inspect the session before retrying."}

  defp mutation_error(%{code: code, message: message}) when is_binary(message) do
    if String.contains?(message, "detected dubious ownership"),
      do: "Herdr rejected the untrusted repository (#{code}).",
      else: "Herdr rejected the worktree (#{code})."
  end

  defp mutation_error(%{code: code}), do: "Herdr rejected the worktree (#{code})."

  defp error_message(%{code: code, message: message}) when is_binary(message) do
    if String.contains?(message, "detected dubious ownership") do
      "Herdr rejected the untrusted repository (#{code})."
    else
      "Herdr could not list worktrees (#{code})."
    end
  end

  defp error_message(%{code: code}), do: "Herdr could not list worktrees (#{code})."

  defp request(method, params),
    do:
      Socket.request(method, params,
        server: Application.get_env(:jarvis2, :herdr_socket, Socket),
        timeout: 5_000
      )

  defp mirror, do: Application.get_env(:jarvis2, :mirror, Mirror)
end

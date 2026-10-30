defmodule Jarvis2.Kanban.AgentsFile do
  @moduledoc "Validation, drift checks and review of an agents file proposal."

  alias Jarvis2.Kanban.{AtomicFile, Card}

  @names ["AGENTS.md", "CLAUDE.md"]

  def validate(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"content" => text, "changes" => changes}}
      when is_binary(text) and is_list(changes) ->
        validate_proposal(text, changes)

      {:ok, _} ->
        {:error, "Expected a JSON object with content and changes."}

      {:error, _} ->
        {:error, "Invalid JSON; submit one object without Markdown fences."}
    end
  end

  def validate(_), do: {:error, "Expected a JSON object."}

  defp validate_proposal(text, changes) do
    cond do
      not String.valid?(text) or String.trim(text) == "" ->
        {:error, "content must be non-empty UTF-8 text."}

      byte_size(text) > 32_768 ->
        {:error, "content exceeds 32768 bytes."}

      length(changes) > 100 or not Enum.all?(changes, &valid_change?/1) ->
        {:error,
         "changes must contain at most 100 entries with action, section, reason and source."}

      true ->
        :ok
    end
  end

  defp valid_change?(%{
         "action" => action,
         "section" => section,
         "reason" => reason,
         "source" => source
       }) do
    action in ~w(add rewrite remove move) and source in @names and
      nonempty?(section) and nonempty?(reason)
  end

  defp valid_change?(_), do: false

  defp nonempty?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  def fingerprint(cwd) do
    Enum.reduce_while(@names, {:ok, %{}}, fn name, {:ok, acc} ->
      case read(cwd, name) do
        {:ok, _, content} -> {:cont, {:ok, Map.put(acc, name, hash(content))}}
        error -> {:halt, error}
      end
    end)
  end

  def check_base(cwd, base, names \\ @names) do
    if is_map(base) and Enum.all?(names, &Map.has_key?(base, &1)) do
      check_files(cwd, base, names)
    else
      {:error, "The context file baseline is missing; reopen the card."}
    end
  end

  defp check_files(cwd, base, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case check_file(cwd, name, base[name]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_file(cwd, name, expected) do
    with {:ok, _, content} <- read(cwd, name) do
      if hash(content) == expected,
        do: :ok,
        else: {:error, "#{name} changed since the run started; reopen and read it again."}
    end
  end

  def review(%Card{kind: :agents_file, run: %{cwd: cwd}} = card) do
    with :ok <- validate(card.deliverable),
         :ok <- check_base(cwd, card.agents_file_base, ["AGENTS.md"]),
         {:ok, target, old} <- read(cwd, "AGENTS.md"),
         :ok <- writable_target(cwd, target),
         :ok <- valid_old(old) do
      %{"content" => content, "changes" => changes} = Jason.decode!(card.deliverable)
      diff = List.myers_difference(lines(old || ""), lines(content))

      status =
        cond do
          is_nil(old) -> :create
          old == content -> :unchanged
          true -> :update
        end

      {:ok,
       %{
         status: status,
         diff: diff,
         removed_lines: count(diff, :del),
         added_lines: count(diff, :ins),
         changes: changes,
         content: content,
         path: Path.join(cwd, "AGENTS.md")
       }}
    end
  end

  def review(_), do: {:error, "The card has no agents file run."}

  def apply!(%Card{} = card) do
    with {:ok, review} <- review(card),
         {:ok, target, _} <- read(card.run.cwd, "AGENTS.md"),
         :ok <- writable_target(card.run.cwd, target),
         :ok <- check_base(card.run.cwd, card.agents_file_base, ["AGENTS.md"]),
         :ok <- AtomicFile.write(target, review.content) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "Could not write AGENTS.md in the working directory."}
    end
  end

  defp writable_target(cwd, target) do
    with {:ok, root} <- resolve(Path.expand(cwd)) do
      if target == Path.join(root, "CLAUDE.md"),
        do: {:error, "AGENTS.md points to CLAUDE.md; refusing to write CLAUDE.md."},
        else: :ok
    end
  end

  defp valid_old(nil), do: :ok

  defp valid_old(text) do
    if String.valid?(text),
      do: :ok,
      else: {:error, "AGENTS.md is not valid UTF-8; cannot display a diff."}
  end

  defp count(diff, kind),
    do:
      Enum.reduce(diff, 0, fn {k, lines}, acc ->
        if k == kind, do: acc + length(lines), else: acc
      end)

  defp lines(text), do: Regex.scan(~r/[^\n]*\n|[^\n]+\z/u, text) |> Enum.map(&hd/1)
  defp hash(nil), do: nil
  defp hash(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp read(cwd, name) do
    with {:ok, root} <- resolve(Path.expand(cwd)),
         {:ok, target} <- resolve(Path.join(root, name)),
         true <- root == "/" or target == root or String.starts_with?(target, root <> "/"),
         result <- File.read(target) do
      case result do
        {:ok, content} -> {:ok, target, content}
        {:error, :enoent} -> {:ok, target, nil}
        _ -> {:error, "Could not read #{name} in the working directory."}
      end
    else
      false -> {:error, "#{name} resolves outside the working directory."}
      _ -> {:error, "Could not safely resolve #{name} in the working directory."}
    end
  end

  defp resolve(path), do: resolve_parts(Path.split(path), "", 0)
  defp resolve_parts(_, _, n) when n > 40, do: {:error, :eloop}
  defp resolve_parts([], current, _), do: {:ok, current}

  defp resolve_parts([part | rest], current, n) do
    path = if current == "" and part == "/", do: "/", else: Path.join(current, part)

    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        with {:ok, link} <- File.read_link(path) do
          target = Path.expand(link, Path.dirname(path))
          resolve_parts(Path.split(Path.join([target | rest])), "", n + 1)
        end

      {:ok, _} ->
        resolve_parts(rest, path, n)

      {:error, :enoent} when rest == [] ->
        {:ok, path}

      error ->
        error
    end
  end
end

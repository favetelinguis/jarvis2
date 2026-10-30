defmodule Jarvis2.Roles do
  @moduledoc "Reads and validates trusted role files on demand."
  alias Jarvis2.Runs.Run

  defmodule Role do
    @moduledoc false
    defstruct [:name, :description, :model, :effort, :prompt, subagent: false]
  end

  def dir, do: Application.fetch_env!(:jarvis2, :roles_dir)

  def list do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&load/1)

      {:error, reason} ->
        [
          {:error,
           %{file: dir(), reason: "cannot read roles directory: #{:file.format_error(reason)}"}}
        ]
    end
  end

  def get(name) when is_binary(name) do
    case Enum.find(list(), fn
           {:ok, role} -> role.name == name
           {:error, %{file: file}} -> Path.rootname(file, ".md") == name
         end) do
      {:ok, role} -> {:ok, role}
      {:error, %{reason: reason}} -> {:error, "Role #{inspect(name)}: #{reason}"}
      nil -> {:error, "Role #{inspect(name)} not found or roles directory unavailable."}
    end
  end

  def get(_), do: {:error, "Invalid role name."}

  defp load(file) do
    result =
      with {:ok, text} <- File.read(Path.join(dir(), file)),
           true <- String.valid?(text) || {:error, "file is not valid UTF-8"},
           ["", header, body] <- Regex.split(~r/^---\s*\r?$/m, text, parts: 3),
           {:ok, frontmatter} <- YamlElixir.read_from_string(header),
           true <- is_map(frontmatter) || {:error, "frontmatter must be a map"},
           {:ok, role} <- validate(frontmatter, body, file) do
        {:ok, role}
      else
        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} when is_atom(reason) ->
          {:error, "cannot read file: #{:file.format_error(reason)}"}

        _ ->
          {:error, "missing or malformed frontmatter"}
      end

    case result do
      {:ok, role} -> {:ok, role}
      {:error, reason} -> {:error, %{file: file, reason: reason}}
    end
  end

  defp validate(data, body, file) do
    prompt = String.trim(body)

    with :ok <- validate_header(data, file),
         :ok <- validate_subagent(data),
         true <- prompt != "" || {:error, "prompt body is empty"} do
      {:ok,
       %Role{
         name: data["name"],
         description: data["description"],
         model: data["model"],
         effort: data["effort"],
         prompt: prompt,
         subagent: Map.get(data, "subagent", false)
       }}
    end
  end

  defp validate_header(data, file) do
    name = data["name"]
    model = data["model"]
    effort = data["effort"]
    description = data["description"]

    cond do
      not valid_name?(name) ->
        {:error, "invalid name"}

      name != Path.rootname(file, ".md") ->
        {:error, "name must match file stem"}

      not valid_description?(description) ->
        {:error, "description must be a string"}

      not is_nil(model) and not Run.valid_model?(model) ->
        {:error, "invalid model; expected provider/model"}

      not is_nil(effort) and effort not in Run.thinking_levels() ->
        {:error, "invalid effort"}

      true ->
        :ok
    end
  end

  defp validate_subagent(data) do
    if is_boolean(Map.get(data, "subagent", false)),
      do: :ok,
      else: {:error, "subagent must be a boolean"}
  end

  defp valid_name?(name) when is_binary(name) do
    byte_size(name) <= 64 and Regex.match?(~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, name)
  end

  defp valid_name?(_), do: false

  defp valid_description?(description), do: is_nil(description) or is_binary(description)
end

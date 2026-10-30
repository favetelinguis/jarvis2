defmodule Jarvis2.Kanban.AtomicFile do
  @moduledoc false

  def write(target, content) do
    temp = Path.join(Path.dirname(target), ".#{Path.basename(target)}-#{Ecto.UUID.generate()}")

    result =
      with {:ok, file} <- File.open(temp, [:write, :exclusive, :binary]),
           result <- IO.binwrite(file, content),
           close <- File.close(file),
           :ok <- result,
           :ok <- close,
           :ok <- preserve_mode(target, temp) do
        File.rename(temp, target)
      end

    if result != :ok, do: File.rm(temp)
    result
  end

  defp preserve_mode(target, temp) do
    case File.stat(target) do
      {:ok, stat} -> File.chmod(temp, Bitwise.band(stat.mode, 0o777))
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end

defmodule Jarvis2.Kanban.Slides do
  @moduledoc false

  @policy "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; form-action 'none'; base-uri 'none'"
  @header "sandbox allow-scripts; " <> @policy
  @meta ~s(<meta http-equiv="Content-Security-Policy" content="#{@policy}">)
  @document ~r/\A\s*<!doctype\s+html\s*>\s*<html(?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)?>\s*<head(?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)?>/i
  @forbidden ~r/<\s*(?:link|iframe|object|embed|base)\b[^>]*>|<\s*script\b[^>]*\bsrc\s*=[^>]*>|@import\b/iu
  @attributes ~r/\b(src|poster|srcset)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/iu
  @urls ~r/url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)/iu

  def csp_header, do: @header

  def validate(html) when is_binary(html) do
    if Regex.match?(@document, html) and Regex.match?(~r/<\/html\s*>\s*\z/i, html) do
      case forbidden(html) do
        nil ->
          :ok

        snippet ->
          {:error,
           "Deck loads external resource #{String.slice(snippet, 0, 100)}; inline it or use a data: URI."}
      end
    else
      {:error,
       "Deck must be a complete HTML document beginning with <!doctype html>, <html> and <head>."}
    end
  end

  defp forbidden(html) do
    case Regex.run(@forbidden, html) do
      [snippet | _] -> snippet
      nil -> invalid_attributes(html) || invalid_urls(html)
    end
  end

  defp invalid_attributes(html) do
    Regex.scan(@attributes, html)
    |> Enum.find_value(fn [snippet, name | values] ->
      value = Enum.find(values, "", &(&1 != "")) |> String.trim()

      allowed =
        if String.downcase(name) == "srcset" do
          # A data URL itself contains a comma; disallow multiple candidates rather than
          # treating a later remote candidate as part of the data URL.
          Regex.match?(~r/\Adata:[^\s,]+,[^\s,]+(?:\s+\d+(?:\.\d+)?[wx])?\z/i, value)
        else
          String.starts_with?(String.downcase(value), ["data:", "#"])
        end

      if allowed, do: nil, else: snippet
    end)
  end

  defp invalid_urls(html) do
    Regex.scan(@urls, html)
    |> Enum.find_value(fn [snippet | values] ->
      value = Enum.find(values, "", &(&1 != "")) |> String.trim() |> String.downcase()
      if String.starts_with?(value, "data:"), do: nil, else: snippet
    end)
  end

  def serve(html) do
    [head, rest] = Regex.split(@document, html, parts: 2, include_captures: true, trim: true)
    [head, @meta, rest]
  end

  def filename(title) do
    slug =
      title
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if(slug == "", do: "slides", else: slug) <> ".html"
  end

  def path(card_id) do
    Path.join([Application.fetch_env!(:jarvis2, :state_dir), "slides", card_id <> ".html"])
  end

  def store(card) do
    target = path(card.id)
    temp = target <> "." <> Ecto.UUID.generate()

    result =
      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.chmod(Path.dirname(target), 0o700),
           {:ok, file} <- File.open(temp, [:write, :exclusive, :binary]),
           result <- IO.binwrite(file, card.deliverable),
           close <- File.close(file),
           :ok <- result,
           :ok <- close do
        File.rename(temp, target)
      end

    if result != :ok, do: File.rm(temp)

    if result == :ok,
      do: :ok,
      else: {:error, "Could not save the current slide deck for reopening."}
  end
end

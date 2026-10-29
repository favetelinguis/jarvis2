defmodule Jarvis2.Kanban.SlidesTest do
  use ExUnit.Case, async: true
  alias Jarvis2.Kanban.Slides

  @deck "<!doctype html><html><head><title>Deck</title></head><body>%s</body></html>"

  test "accepts documents with inline resources and source links" do
    html =
      String.replace(
        @deck,
        "%s",
        ~s(<img src="data:image/png;base64,AA=="><a href="https://example.com">Source</a>)
      )

    assert :ok = Slides.validate(html)
    served = IO.iodata_to_binary(Slides.serve(html))
    assert served =~ ~s(http-equiv="Content-Security-Policy")
    assert length(String.split(served, ~s(http-equiv="Content-Security-Policy"))) == 2
    assert Slides.filename("Q3: A/B résumé!") == "q3-a-b-resume.html"
    assert Slides.filename("!!!") == "slides.html"
  end

  test "rejects non-documents and external resources" do
    for invalid <- [
          "# Markdown",
          "```html\n" <> @deck <> "\n```",
          "<!doctype html><script>alert(1)</script><html><head></head></html>"
        ] do
      assert {:error, _} = Slides.validate(invalid)
    end

    for resource <- [
          ~s(<script src="https://example.com/a.js"></script>),
          ~s|<script src="data:text/javascript,alert(1)"></script>|,
          ~s(<link rel="stylesheet" href="https://example.com/a.css">),
          ~s(<img src="https://example.com/a.png">),
          ~s(<video poster="/poster.png"></video>),
          ~s(<img srcset="data:image/png;base64,AA 1x, https://example.com/a.png 2x">),
          "<style>div { background: url(https://example.com/x) }</style>",
          ~s(<style>@import 'https://example.com/x';</style>),
          ~s(<iframe src="data:text/html,test"></iframe>),
          ~s(<base href="https://example.com">)
        ] do
      assert {:error, message} = Slides.validate(String.replace(@deck, "%s", resource))
      assert message =~ "inline it"
    end
  end
end

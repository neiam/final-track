defmodule FinalTrackWeb.PageControllerTest do
  use FinalTrackWeb.ConnCase

  test "GET /about renders the about page inside the shared chrome", %{conn: conn} do
    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_document()

    for selector <-
          ~w(#brand #theme-toggle #hero #hero-live #features #feature-live #feature-library #feature-private #who-sees-what #steps #footer) do
      refute Enum.empty?(LazyHTML.query(doc, selector)), "missing #{selector}"
    end
  end

  test "theme picker lists system plus every theme", %{conn: conn} do
    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_document()

    offered =
      doc
      |> LazyHTML.query("button[data-phx-theme]")
      |> LazyHTML.attribute("data-phx-theme")

    assert offered == ["system" | FinalTrack.Themes.all()]
  end

  test "features that are on here are described; federation is on in test", %{conn: conn} do
    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_document()
    refute Enum.empty?(LazyHTML.query(doc, "#feature-fediverse"))
    # NEIAM sign-in is off (OIDC_ENABLED unset): not advertised.
    assert Enum.empty?(LazyHTML.query(doc, "#feature-sso"))
  end
end

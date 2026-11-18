defmodule FinalTrackWeb.AboutLiveTest do
  use FinalTrackWeb.ConnCase

  test "renders inside the shared chrome", %{conn: conn} do
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

  describe "run your own" do
    import Phoenix.LiveViewTest

    test "ready-to-copy commands, podman by default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/about")

      assert has_element?(lv, "#run-your-own")
      assert has_element?(lv, "#runtime-podman[aria-selected=true]")
      assert has_element?(lv, "#db-command", "podman network create final-track")
      assert has_element?(lv, "#db-command", "POSTGRES_DB=final_track")
      assert has_element?(lv, "#run-command", "--network final-track")
      assert has_element?(lv, "#run-command", "ecto://USER:PASS@final-track-db/final_track")
      assert has_element?(lv, "#registry-ghcr[aria-selected=true]")
      assert has_element?(lv, "#run-command", "ghcr.io/neiam/final_track:latest")
      assert has_element?(lv, "#run-command", "-v final-track-covers:/var/lib/final_track/covers")
      assert has_element?(lv, "#setup-command", "podman exec final-track bin/migrate")
      assert has_element?(lv, "#setup-command", "bin/invite")
      lv |> element("#registry-quay") |> render_click()
      assert has_element?(lv, "#run-command", "quay.io/neiam/final_track:latest")
      lv |> element("#registry-dockerhub") |> render_click()
      assert has_element?(lv, "#run-command", "docker.io/neiam/final_track:latest")
    end

    test "switch runtime, fill in the blanks", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/about")

      lv |> element("#runtime-docker") |> render_click()
      assert has_element?(lv, "#run-command", "docker run -d --name final-track")
      assert has_element?(lv, "#setup-command", "docker exec final-track bin/migrate")

      lv
      |> form("#run-config", %{user: "tracks", password: "s3cret", host: "music.example.org"})
      |> render_change()

      assert has_element?(lv, "#run-command", "PHX_HOST=music.example.org")
      assert has_element?(lv, "#run-command", "ecto://tracks:s3cret@final-track-db/final_track")
      assert has_element?(lv, "#db-command", "POSTGRES_USER=tracks")

      # Blank again: back to the placeholders.
      lv |> form("#run-config", %{user: " ", password: "", host: ""}) |> render_change()
      assert has_element?(lv, "#run-command", "PHX_HOST=tracks.you.com")
    end

    test "a forged runtime is ignored, never turned into an atom", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/about")
      render_hook(lv, "set_runtime", %{"runtime" => "rkt-#{System.unique_integer()}"})
      assert has_element?(lv, "#runtime-podman[aria-selected=true]")
    end
  end

  test "OpenID Connect, not NEIAM, in the copy", %{conn: conn} do
    html = conn |> get(~p"/about") |> html_response(200)
    refute html =~ "Sign in with NEIAM"
    assert html =~ "OpenID Connect"
  end
end

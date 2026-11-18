defmodule FinalTrackWeb.FederationOffTest do
  # Changes app config: not async.
  use FinalTrackWeb.ConnCase, async: false

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures
  import FinalTrack.FederationHelpers
  import Phoenix.LiveViewTest

  alias FinalTrack.Repo
  alias FinalTrack.Federation.Post

  setup do
    previous = Application.get_env(:final_track, FinalTrack.Federation)
    user = user_fixture()
    fedi_account(user)

    Application.put_env(
      :final_track,
      FinalTrack.Federation,
      Keyword.put(previous, :enabled, false)
    )

    on_exit(fn -> Application.put_env(:final_track, FinalTrack.Federation, previous) end)
    %{user: user}
  end

  test "every ActivityPub route is 404, and nothing is posted", %{conn: conn, user: user} do
    for path <- [
          "/.well-known/webfinger?resource=acct:alice@localhost",
          "/.well-known/nodeinfo",
          "/nodeinfo/2.0",
          "/ap/actor",
          "/ap/users/alice",
          "/ap/users/alice/outbox",
          "/.well-known/host-meta",
          "/@alice",
          "/tags/scropple"
        ] do
      assert response(get(conn, path), 404), path
    end

    assert response(
             conn
             |> put_req_header("content-type", "application/activity+json")
             |> post("/ap/inbox", "{}"),
             404
           )

    play_fixture(user)
    assert Repo.all(Post) == []
  end

  test "the about page doesn't advertise it", %{conn: conn} do
    html = conn |> get(~p"/about") |> html_response(200)
    refute html =~ "feature-fediverse"
    refute html =~ "Your followers"
  end

  test "the settings section is hidden", %{conn: conn, user: user} do
    {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/scrobbling")
    refute has_element?(lv, "#fediverse")
  end
end

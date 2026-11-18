defmodule FinalTrackWeb.UserLive.FediverseSettingsTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.Federation

  setup :register_and_log_in_user

  test "set up an account, then switch it off", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/scrobbling")
    assert has_element?(lv, "#fediverse")
    refute has_element?(lv, "#fediverse-status")

    lv
    |> form("#fediverse-form", fediverse: %{username: "Alice", enabled: "true"})
    |> render_submit()

    assert %{username: "alice", enabled: true} = Federation.get_account(user)
    assert has_element?(lv, "#fediverse-status", "@alice@localhost")
    assert has_element?(lv, "#fediverse-status", "posting")

    # Followers only by default; public on request.
    assert %{visibility: "unlisted"} = Federation.get_account(user)
    assert has_element?(lv, "#fediverse-visibility", "followers only")
    lv |> form("#fediverse-form", fediverse: %{visibility: "public"}) |> render_submit()
    assert %{visibility: "public"} = Federation.get_account(user)
    assert has_element?(lv, "#fediverse-visibility", "public")

    # #scropple by default; changeable.
    assert %{hashtag: "scropple"} = Federation.get_account(user)
    lv |> form("#fediverse-form", fediverse: %{hashtag: "#nowplaying"}) |> render_submit()
    assert %{hashtag: "nowplaying"} = Federation.get_account(user)

    lv |> form("#fediverse-form", fediverse: %{enabled: "false"}) |> render_submit()
    assert %{enabled: false} = Federation.get_account(user)
    assert has_element?(lv, "#fediverse-status", "off")
  end

  test "a taken or invalid username is explained", %{conn: conn} do
    {:ok, _} = Federation.save_account(user_fixture(), %{username: "taken"})
    {:ok, lv, _html} = live(conn, ~p"/users/scrobbling")

    html = lv |> form("#fediverse-form", fediverse: %{username: "taken"}) |> render_submit()
    assert html =~ "has already been taken"

    html = lv |> form("#fediverse-form", fediverse: %{username: "no spaces!"}) |> render_change()
    assert html =~ "only lowercase letters"
  end
end

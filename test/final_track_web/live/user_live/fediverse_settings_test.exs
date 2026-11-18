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

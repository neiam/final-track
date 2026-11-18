defmodule FinalTrackWeb.UserLive.ScrobblingTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FinalTrack.{Catalog, Privacy, Scrobbles}

  setup :register_and_log_in_user

  test "make a token: shown once, and it works", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/scrobbling")
    assert has_element?(lv, "#tokens-empty")
    assert has_element?(lv, "#setup-base-url")

    lv |> form("#token-form", token: %{label: "Pixel 8"}) |> render_submit()

    token =
      lv
      |> element("#new-token-value")
      |> render()
      |> then(&Regex.run(~r/value="([^"]+)"/, &1, capture: :all_but_first))
      |> hd()

    assert {:ok, %{id: id}} = Scrobbles.verify_token(token)
    assert id == user.id
    assert has_element?(lv, "#tokens", "Pixel 8")

    lv |> element("#dismiss-token") |> render_click()
    refute has_element?(lv, "#new-token")
  end

  test "revoke a token", %{conn: conn, user: user} do
    {:ok, plaintext, token} = Scrobbles.create_token(user, %{"label" => "Old phone"})
    {:ok, lv, _html} = live(conn, ~p"/users/scrobbling")

    lv |> element("#revoke-tokens-#{token.id}") |> render_click()
    assert :error = Scrobbles.verify_token(plaintext)
    refute has_element?(lv, "#tokens", "Old phone")
  end

  test "lists what's kept private and shares it again", %{conn: conn, user: user} do
    artist = Catalog.ensure_artist!("Pink Floyd")
    :ok = Privacy.mark(user, artist)
    [mark] = Privacy.list_marks(user)

    {:ok, lv, _html} = live(conn, ~p"/users/scrobbling")
    assert has_element?(lv, "#mark-#{mark.id}", "Pink Floyd")

    lv |> element("#unmark-#{mark.id}") |> render_click()
    refute Privacy.private?(user, artist)
    assert has_element?(lv, "#no-private-marks")
  end
end

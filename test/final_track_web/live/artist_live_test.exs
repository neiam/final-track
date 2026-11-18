defmodule FinalTrackWeb.ArtistLiveTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Privacy}

  setup :register_and_log_in_user

  test "albums, top tracks and the private switch", %{conn: conn, user: user} do
    play_fixture(user)
    artist = Catalog.ensure_artist!("Pink Floyd")
    album = Catalog.ensure_album!(artist, "The Dark Side of the Moon")

    {:ok, lv, _html} = live(conn, ~p"/artists/#{artist.id}")
    assert has_element?(lv, "#artist-name", "Pink Floyd")
    assert has_element?(lv, "#album-#{album.id}")
    assert has_element?(lv, "#artist-tracks", "Time")

    lv |> element("#artist-private") |> render_click()
    assert Privacy.private?(user, artist)
    # Tracks can't be toggled one by one under a private artist.
    refute has_element?(lv, "[id^=track-private-]")
  end
end

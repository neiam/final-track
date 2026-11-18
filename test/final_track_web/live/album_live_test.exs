defmodule FinalTrackWeb.AlbumLiveTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Charts, Privacy}

  setup :register_and_log_in_user

  setup %{user: user} do
    play_fixture(user)
    play_fixture(user, %{"track" => "Money"})
    artist = Catalog.ensure_artist!("Pink Floyd")
    %{album: Catalog.ensure_album!(artist, "The Dark Side of the Moon"), artist: artist}
  end

  test "shows the album and its tracks", %{conn: conn, album: album} do
    {:ok, lv, _html} = live(conn, ~p"/albums/#{album.id}")
    assert has_element?(lv, "#album-title", "The Dark Side of the Moon")
    assert has_element?(lv, "#album-artist", "Pink Floyd")
    assert has_element?(lv, "#album-tracks", "Money")
    refute has_element?(lv, "#remove-cover")
  end

  test "an unknown album goes back to the charts", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/charts"}}} =
             live(conn, ~p"/albums/#{Ecto.UUID.generate()}")
  end

  test "upload a cover", %{conn: conn, album: album} do
    {:ok, lv, _html} = live(conn, ~p"/albums/#{album.id}")

    cover =
      file_input(lv, "#cover-form", :cover, [
        %{name: "cover.png", content: png_bytes(), type: "image/png"}
      ])

    render_upload(cover, "cover.png")

    assert Catalog.get_album!(album.id).cover_source == "upload"
    assert has_element?(lv, "#album-cover img")
    assert has_element?(lv, "#remove-cover")

    lv |> element("#remove-cover") |> render_click()
    refute Catalog.get_album!(album.id).cover_key
    refute has_element?(lv, "#album-cover img")
  end

  test "an upload that isn't an image is refused", %{conn: conn, album: album} do
    {:ok, lv, _html} = live(conn, ~p"/albums/#{album.id}")

    cover =
      file_input(lv, "#cover-form", :cover, [
        %{name: "cover.png", content: "nope", type: "image/png"}
      ])

    render_upload(cover, "cover.png")

    refute Catalog.get_album!(album.id).cover_key
    assert render(lv) =~ "isn&#39;t a JPEG, PNG or WebP"
  end

  test "keep the album, or one track, private", %{
    conn: conn,
    album: album,
    artist: artist,
    user: user
  } do
    {:ok, lv, _html} = live(conn, ~p"/albums/#{album.id}")

    lv |> element("#album-private") |> render_click()
    assert Privacy.private?(user, album)
    assert has_element?(lv, "#album-private[aria-pressed=true]")

    other = user_fixture()
    assert %{plays: 0} = Charts.summary(album, Charts.audience(other))

    lv |> element("#album-private") |> render_click()
    refute Privacy.private?(user, album)

    money = Catalog.ensure_track!(artist, "Money")
    lv |> element("#track-private-#{money.id}") |> render_click()
    assert Privacy.private?(user, money)
    assert %{plays: 1} = Charts.summary(album, Charts.audience(other))
  end
end

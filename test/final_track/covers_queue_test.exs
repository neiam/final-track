defmodule FinalTrack.CoversQueueTest do
  @moduledoc """
  Tests that drive the global cover-lookup queue (one process for the whole
  app). They lend it their DB sandbox and HTTP stub, so two at once would
  race for it: not async.
  """
  use FinalTrackWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Covers, Repo}

  defp stub(search, cover) do
    Req.Test.stub(FinalTrack.Covers.Fetcher, fn conn ->
      case conn.host do
        "musicbrainz.org" -> search.(conn)
        "coverartarchive.org" -> cover.(conn)
      end
    end)
  end

  setup do
    Covers.subscribe()
    artist = Catalog.ensure_artist!("Pink Floyd")

    album =
      artist |> Catalog.ensure_album!("The Dark Side of the Moon") |> Map.put(:artist, artist)

    %{album: album, artist: artist}
  end

  test "retry_misses/0 counts the albums that never matched", %{album: album} do
    {:ok, _} = Catalog.mark_cover_checked(album)
    other = Catalog.ensure_album!(album.artist, "Meddle")
    {:ok, _} = Catalog.mark_cover_checked(other, %{mbid: "known-but-no-art"})

    # Only the first: the second matched, the archive just has no art.
    stub(&Req.Test.json(&1, %{"release-groups" => []}), &Plug.Conn.send_resp(&1, 404, ""))
    # The queue is global: let it use this test's stub (made first) and DB.
    queue = Process.whereis(FinalTrack.Covers.Queue)
    Ecto.Adapters.SQL.Sandbox.allow(FinalTrack.Repo, self(), queue)
    Req.Test.allow(FinalTrack.Covers.Fetcher, self(), queue)
    assert Covers.retry_misses() == 1
    album_id = album.id
    assert_receive {:cover_fetch_failed, ^album_id, :no_match}
  end

  describe "on the album page" do
    setup :register_and_log_in_user

    setup %{user: user} do
      play_fixture(user)
      :ok
    end

    test "fetch a cover through the queue", %{conn: conn, album: album} do
      Req.Test.stub(FinalTrack.Covers.Fetcher, fn
        %{host: "musicbrainz.org"} = conn ->
          Req.Test.json(conn, %{
            "release-groups" => [%{"id" => Ecto.UUID.generate(), "score" => 100}]
          })

        conn ->
          Plug.Conn.send_resp(conn, 200, png_bytes())
      end)

      # The queue is a global process: let it use this test's stub and DB.
      queue = Process.whereis(FinalTrack.Covers.Queue)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), queue)
      Req.Test.allow(FinalTrack.Covers.Fetcher, self(), queue)

      {:ok, lv, _html} = live(conn, ~p"/albums/#{album.id}")
      lv |> element("#fetch-cover") |> render_click()

      # The queue's broadcast reaches the page; wait for it to re-render.
      _ = :sys.get_state(queue)
      _ = :sys.get_state(lv.pid)
      assert has_element?(lv, "#album-cover img")
      assert Catalog.get_album!(album.id).cover_source == "coverartarchive"
    end
  end
end

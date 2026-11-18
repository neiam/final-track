defmodule FinalTrack.CoversTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Covers}
  alias FinalTrack.Covers.Store

  @mbid "f5093c06-23e3-404f-aeaa-40f72885ee3a"

  setup do
    Covers.subscribe()
    artist = Catalog.ensure_artist!("Pink Floyd")

    album =
      artist |> Catalog.ensure_album!("The Dark Side of the Moon") |> Map.put(:artist, artist)

    %{album: album}
  end

  # MusicBrainz search, then the Cover Art Archive.
  defp stub(search, cover) do
    Req.Test.stub(FinalTrack.Covers.Fetcher, fn conn ->
      case conn.host do
        "musicbrainz.org" -> search.(conn)
        "coverartarchive.org" -> cover.(conn)
      end
    end)
  end

  defp found(score \\ 100),
    do: &Req.Test.json(&1, %{"release-groups" => [%{"id" => @mbid, "score" => score}]})

  test "fetch: finds the release group, stores the front cover", %{album: album} do
    test = self()

    stub(
      fn conn ->
        send(
          test,
          {:query, conn.query_params["query"], Plug.Conn.get_req_header(conn, "user-agent")}
        )

        found().(conn)
      end,
      fn conn ->
        send(test, {:cover_path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, png_bytes())
      end
    )

    assert {:ok, album} = Covers.fetch_cover_now(album.id)

    assert_received {:query, ~s(releasegroup:"The Dark Side of the Moon" AND artist:"Pink Floyd"),
                     [ua]}

    assert ua =~ "FinalTrack"
    assert_received {:cover_path, "/release-group/" <> @mbid <> "/front-500"}

    assert album.cover_source == "coverartarchive"
    assert album.mbid == @mbid
    assert String.ends_with?(album.cover_key, ".png")
    assert {:ok, path} = Store.fetch(album.cover_key)
    assert File.read!(path) == png_bytes()

    album_id = album.id
    assert_receive {:cover_updated, ^album_id}
  end

  test "fetch: unknown album or no cover is remembered; a network failure isn't", %{album: album} do
    stub(&Req.Test.json(&1, %{"release-groups" => []}), &Plug.Conn.send_resp(&1, 500, ""))
    assert {:error, :no_match} = Covers.fetch_cover_now(album.id)
    assert Catalog.get_album!(album.id).cover_checked_at

    stub(found(), &Plug.Conn.send_resp(&1, 404, ""))
    assert {:error, :no_cover} = Covers.fetch_cover_now(album.id)
    assert Catalog.get_album!(album.id).mbid == @mbid

    other = Catalog.ensure_album!(album.artist, "Meddle")
    stub(&Plug.Conn.send_resp(&1, 503, ""), &Plug.Conn.send_resp(&1, 500, ""))

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, :unavailable} = Covers.fetch_cover_now(other.id)
    end)

    refute Catalog.get_album!(other.id).cover_checked_at
    other_id = other.id
    assert_receive {:cover_fetch_failed, ^other_id, :unavailable}
  end

  test "fetch: a weak MusicBrainz match is no match", %{album: album} do
    stub(found(60), &Plug.Conn.send_resp(&1, 200, png_bytes()))
    assert {:error, :no_match} = Covers.fetch_cover_now(album.id)
  end

  test "fetch: what comes back must really be an image", %{album: album} do
    stub(found(), &Plug.Conn.send_resp(&1, 200, "<html>not a cover</html>"))
    assert {:error, :not_an_image} = Covers.fetch_cover_now(album.id)
  end

  test "upload: sniffed by content, replaces the previous file; remove deletes it", %{
    album: album
  } do
    path = Path.join(System.tmp_dir!(), "cover-#{System.unique_integer([:positive])}")
    File.write!(path, jpeg_bytes())
    assert {:ok, first} = Covers.put_upload(album, path)
    assert first.cover_source == "upload"
    assert String.ends_with?(first.cover_key, ".jpg")

    File.write!(path, png_bytes())
    assert {:ok, second} = Covers.put_upload(first, path)
    assert {:error, :not_found} = Store.fetch(first.cover_key)
    assert {:ok, _} = Store.fetch(second.cover_key)

    File.write!(path, "GIF89a not really")
    assert {:error, :not_an_image} = Covers.put_upload(second, path)

    assert {:ok, removed} = Covers.remove(second)
    assert removed.cover_key == nil
    assert {:error, :not_found} = Store.fetch(second.cover_key)
  end

  test "maybe_fetch/1 only queues what was never tried, and only when enabled", %{album: album} do
    # Test config has auto_fetch off: nothing is queued.
    assert :ok = Covers.maybe_fetch(album)
    assert :ok = Covers.maybe_fetch(%{album | cover_checked_at: DateTime.utc_now()})
  end
end

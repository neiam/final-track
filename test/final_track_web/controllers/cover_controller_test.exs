defmodule FinalTrackWeb.CoverControllerTest do
  use FinalTrackWeb.ConnCase, async: true

  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Covers}

  setup do
    artist = Catalog.ensure_artist!("Pink Floyd")
    album = Catalog.ensure_album!(artist, "The Dark Side of the Moon")
    path = Path.join(System.tmp_dir!(), "cover-#{System.unique_integer([:positive])}")
    File.write!(path, png_bytes())
    {:ok, album} = Covers.put_upload(album, path)
    %{album: album}
  end

  test "signed out too: the landing grid is public", %{conn: conn, album: album} do
    conn = get(conn, ~p"/covers/#{album.id}")
    assert response(conn, 200) == png_bytes()
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "serves the image, cacheable", %{conn: conn, album: album} do
      conn = get(conn, ~p"/covers/#{album.id}")
      assert response(conn, 200) == png_bytes()
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert [cache] = get_resp_header(conn, "cache-control")
      assert cache =~ "public"
      assert cache =~ "immutable"
    end

    test "404 for no cover or no album", %{conn: conn, album: album} do
      {:ok, _} = Covers.remove(album)
      assert response(get(conn, ~p"/covers/#{album.id}"), 404)
      assert response(get(conn, ~p"/covers/not-a-uuid"), 404)
    end
  end
end

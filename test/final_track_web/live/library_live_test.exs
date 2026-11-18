defmodule FinalTrackWeb.LibraryLiveTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.Catalog

  test "signed out: off to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/artists")
  end

  describe "signed in" do
    setup :register_and_log_in_user

    setup %{user: user} do
      play_fixture(user)
      play_fixture(user, %{"track" => "Money"})

      play_fixture(user_fixture(), %{
        "artist" => "Air",
        "track" => "Sexy Boy",
        "album" => "Moon Safari"
      })

      %{floyd: Catalog.ensure_artist!("Pink Floyd"), air: Catalog.ensure_artist!("Air")}
    end

    test "artists with their plays", %{conn: conn, floyd: floyd, air: air} do
      {:ok, lv, _html} = live(conn, ~p"/artists")

      assert has_element?(lv, "#tab-artists[aria-selected=true]")
      assert has_element?(lv, "#library-count", "2 artists")
      assert has_element?(lv, "#rows-#{floyd.id}", "Pink Floyd")
      assert has_element?(lv, "#rows-#{floyd.id}", "2")
      assert has_element?(lv, "#rows-#{air.id}", "Air")
    end

    test "albums tab, with covers and artists", %{conn: conn, floyd: floyd} do
      album = Catalog.ensure_album!(floyd, "The Dark Side of the Moon")
      {:ok, lv, _html} = live(conn, ~p"/artists")

      lv |> element("#tab-albums") |> render_click()
      assert_patch(lv, ~p"/albums")
      assert has_element?(lv, "#rows-#{album.id}", "The Dark Side of the Moon")
      assert has_element?(lv, "#rows-#{album.id}", "Pink Floyd")
    end

    test "search, sort and me", %{conn: conn, floyd: floyd, air: air} do
      {:ok, lv, _html} = live(conn, ~p"/artists")

      lv |> form("#library-search", library: %{q: "air"}) |> render_change()
      assert_patch(lv, ~p"/artists?q=air")
      assert has_element?(lv, "#rows-#{air.id}")
      refute has_element?(lv, "#rows-#{floyd.id}")

      lv |> form("#library-search", library: %{q: "zzz"}) |> render_change()
      assert has_element?(lv, "#library-empty", "Nothing matches")

      {:ok, lv, _html} = live(conn, ~p"/artists")
      lv |> element("#sort-name") |> render_click()
      assert_patch(lv, ~p"/artists?sort=name")

      lv |> element("#who-me") |> render_click()
      assert has_element?(lv, "#rows-#{floyd.id}")
      refute has_element?(lv, "#rows-#{air.id}")
    end

    test "loads more as you scroll", %{conn: conn, user: user} do
      for i <- 1..55, do: play_fixture(user, %{"artist" => "Band #{i}", "track" => "t"})
      {:ok, lv, _html} = live(conn, ~p"/artists?sort=name")

      assert has_element?(lv, "#library-more")
      refute has_element?(lv, "#library-rows", "Pink Floyd")

      render_hook(lv, "load_more", %{})
      assert has_element?(lv, "#library-rows", "Pink Floyd")
      refute has_element?(lv, "#library-more")
    end
  end
end

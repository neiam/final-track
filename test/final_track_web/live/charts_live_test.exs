defmodule FinalTrackWeb.ChartsLiveTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  test "signed out: off to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/charts")
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "this week's charts, everyone's by default", %{conn: conn, user: user} do
      play_fixture(user)

      play_fixture(user_fixture(), %{
        "artist" => "Air",
        "track" => "Sexy Boy",
        "album" => "Moon Safari"
      })

      {:ok, lv, _html} = live(conn, ~p"/charts")

      assert has_element?(lv, "#period-week[aria-selected=true]")
      assert has_element?(lv, "#total-plays", "2 plays")
      assert has_element?(lv, "#top-artists", "Pink Floyd")
      assert has_element?(lv, "#top-artists", "Air")
      assert has_element?(lv, "#top-albums", "The Dark Side of the Moon")
      assert has_element?(lv, "#top-tracks", "Time")
      assert has_element?(lv, "#recent-plays", "Sexy Boy")

      # Tracks and artists are links: a play to its album, an artist to theirs.
      floyd = FinalTrack.Catalog.ensure_artist!("Pink Floyd")
      album = FinalTrack.Catalog.ensure_album!(floyd, "The Dark Side of the Moon")
      assert has_element?(lv, ~s(#top-tracks a[href="/artists/#{floyd.id}"]), "Time")
      assert has_element?(lv, ~s(#recent-plays a[href="/albums/#{album.id}"]), "Time")
      assert has_element?(lv, ~s(#recent-plays a[href="/artists/#{floyd.id}"]), "Pink Floyd")
    end

    test "me narrows to my plays", %{conn: conn, user: user} do
      play_fixture(user)
      play_fixture(user_fixture(), %{"artist" => "Air", "track" => "Sexy Boy"})

      {:ok, lv, _html} = live(conn, ~p"/charts")
      lv |> element("#who-me") |> render_click()

      assert_patch(
        lv,
        ~p"/charts?#{[date: Date.utc_today() |> Date.beginning_of_week() |> Date.to_iso8601(), period: :week, who: :me]}"
      )

      assert has_element?(lv, "#total-plays", "1 play")
      refute has_element?(lv, "#top-artists", "Air")
    end

    test "period units and navigation", %{conn: conn, user: user} do
      play_fixture(user, %{"timestamp" => unix("2025-03-10T12:00:00Z")})

      {:ok, lv, _html} = live(conn, ~p"/charts?period=year&date=2025-06-01")
      assert has_element?(lv, "#period-title", "2025")
      assert has_element?(lv, "#total-plays", "1 play")

      lv |> element("#period-next") |> render_click()
      assert has_element?(lv, "#period-title", "2026")

      lv |> element("#period-month") |> render_click()
      assert has_element?(lv, "#period-month[aria-selected=true]")

      {:ok, lv, _html} = live(conn, ~p"/charts?period=day&date=2025-03-10")
      assert has_element?(lv, "#period-title", "Mon 10 Mar 2025")
      assert has_element?(lv, "#timeline")
    end

    test "new plays show up live", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/charts")
      refute has_element?(lv, "#top-artists", "Pink Floyd")

      play_fixture(user)
      send(lv.pid, :refresh)
      assert has_element?(lv, "#top-artists", "Pink Floyd")
    end
  end
end

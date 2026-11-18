defmodule FinalTrackWeb.HomeLiveTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Charts, Privacy, Scrobbles}

  setup do
    alice = user_fixture()
    {:ok, alice} = FinalTrack.Accounts.update_user_profile(alice, %{display_name: "Alice"})
    play_fixture(alice, %{"timestamp" => System.os_time(:second) - 120})
    play_fixture(alice, %{"artist" => "Air", "track" => "Sexy Boy", "album" => "Moon Safari"})
    %{alice: alice, play: hd(Scrobbles.recent(Charts.audience(alice), 1))}
  end

  describe "signed out" do
    test "the grid of what was played, but not who played it", %{conn: conn, play: play} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#plays-grid", "Time")
      assert has_element?(lv, "#plays-grid", "Sexy Boy")
      assert has_element?(lv, "#plays-#{play.id}", "Air")
      refute render(lv) =~ "Alice"
      # Album pages are members-only: tiles aren't links.
      refute has_element?(lv, "#plays-#{play.id} a")
      assert has_element?(lv, "#home-about")
    end

    test "anyone's private plays are left out", %{conn: conn, alice: alice} do
      :ok = Privacy.mark(alice, Catalog.ensure_artist!("Air"))
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#plays-grid", "Time")
      refute has_element?(lv, "#plays-grid", "Sexy Boy")
    end

    test "now playing, anonymously", %{conn: conn, alice: alice} do
      {:ok, play} = Scrobbles.validate_play(%{"artist" => "Pink Floyd", "track" => "Breathe"})
      :ok = Scrobbles.set_now_playing(alice, play)

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "#now-#{alice.id}", "Breathe")
      refute has_element?(lv, "#listening-now", "Alice")
    end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "members see who played, and tiles open the album", %{conn: conn, play: play} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#plays-#{play.id}", "Alice")
      assert has_element?(lv, ~s(#plays-#{play.id} a[href="/albums/#{play.album_id}"]))
      assert has_element?(lv, "#home-charts")
    end
  end

  test "new plays arrive live, and stand out", %{conn: conn, alice: alice} do
    {:ok, lv, _html} = live(conn, ~p"/")
    refute has_element?(lv, "#plays-grid", "Money")

    play_fixture(alice, %{"track" => "Money"})
    send(lv.pid, :refresh)

    [new] = Scrobbles.recent(Charts.audience(alice), 1)
    assert has_element?(lv, "#plays-#{new.id}.ring-accent", "Money")
  end

  test "an empty server says so", %{conn: conn} do
    FinalTrack.Repo.delete_all(FinalTrack.Scrobbles.Scrobble)
    {:ok, lv, _html} = live(conn, ~p"/")
    assert has_element?(lv, "#plays-empty")
  end
end

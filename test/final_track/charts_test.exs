defmodule FinalTrack.ChartsTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.Charts
  alias FinalTrack.Charts.Period

  setup do
    %{alice: user_fixture(), bob: user_fixture()}
  end

  test "top lists, totals and the me/everyone split", %{alice: alice, bob: bob} do
    at = unix("2026-11-17T12:00:00Z")

    for i <- 0..2, do: play_fixture(alice, %{"track" => "Time", "timestamp" => at + i})
    play_fixture(alice, %{"track" => "Money", "timestamp" => at + 10})

    play_fixture(bob, %{
      "artist" => "Air",
      "track" => "Kelly Watch the Stars",
      "album" => "Moon Safari",
      "timestamp" => at
    })

    week = Period.containing(:week, ~D[2026-11-17])
    everyone = Charts.audience(alice)

    assert Charts.total_plays(week, "Etc/UTC", everyone) == 5
    assert Charts.total_plays(week, "Etc/UTC", Charts.audience(alice, alice)) == 4

    assert [%{artist: %{name: "Pink Floyd"}, plays: 4}, %{artist: %{name: "Air"}, plays: 1}] =
             Charts.top_artists(week, "Etc/UTC", everyone)

    assert [%{track: %{title: "Time", artist: %{name: "Pink Floyd"}}, plays: 3} | _] =
             Charts.top_tracks(week, "Etc/UTC", everyone)

    assert [
             %{album: %{title: "The Dark Side of the Moon"}, plays: 4},
             %{album: %{title: "Moon Safari"}}
           ] =
             Charts.top_albums(week, "Etc/UTC", everyone)

    # The week before is empty.
    assert Charts.top_artists(Period.previous(week), "Etc/UTC", everyone) == []
  end

  test "days are the viewer's days", %{alice: alice} do
    # 23:30 UTC on the 17th is the 18th in Tokyo (UTC+9).
    play_fixture(alice, %{"timestamp" => unix("2026-11-17T23:30:00Z")})
    audience = Charts.audience(alice)

    assert Charts.total_plays(Period.containing(:day, ~D[2026-11-17]), "Etc/UTC", audience) == 1
    assert Charts.total_plays(Period.containing(:day, ~D[2026-11-18]), "Etc/UTC", audience) == 0

    assert Charts.total_plays(Period.containing(:day, ~D[2026-11-17]), "Asia/Tokyo", audience) ==
             0

    assert Charts.total_plays(Period.containing(:day, ~D[2026-11-18]), "Asia/Tokyo", audience) ==
             1

    tokyo_day = Charts.timeline(Period.containing(:day, ~D[2026-11-18]), "Asia/Tokyo", audience)
    assert length(tokyo_day) == 24
    assert %{label: "08", plays: 1} = Enum.find(tokyo_day, &(&1.plays > 0))
  end

  test "time_zone/1 accepts only zones Postgres knows" do
    assert Charts.time_zone("Europe/Lisbon") == "Europe/Lisbon"
    assert Charts.time_zone("Mars/Olympus_Mons") == "Etc/UTC"
    assert Charts.time_zone("'; drop table users; --") == "Etc/UTC"
    assert Charts.time_zone(nil) == "Etc/UTC"
  end

  test "album and artist summaries", %{alice: alice, bob: bob} do
    play_fixture(alice, %{"timestamp" => unix("2026-11-01T10:00:00Z")})
    play_fixture(bob, %{"timestamp" => unix("2026-11-02T10:00:00Z")})
    play_fixture(bob, %{"track" => "Breathe", "timestamp" => unix("2026-11-03T10:00:00Z")})

    [%{album: album}] =
      Charts.top_albums(
        Period.containing(:year, ~D[2026-11-01]),
        "Etc/UTC",
        Charts.audience(alice)
      )

    audience = Charts.audience(alice)

    assert %{plays: 3, listeners: 2} = Charts.summary(album, audience)

    assert [%{track: %{title: "Time"}, plays: 2}, %{track: %{title: "Breathe"}, plays: 1}] =
             Charts.album_tracks(album, audience)

    assert [%{album: %{id: id}, plays: 3}] = Charts.artist_albums(album.artist, audience)
    assert id == album.id
  end
end

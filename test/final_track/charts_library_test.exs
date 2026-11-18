defmodule FinalTrack.ChartsLibraryTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Charts, Privacy}

  setup do
    alice = user_fixture()
    bob = user_fixture()
    t = unix("2026-11-01T12:00:00Z")

    # Pink Floyd: 3 plays (2 people, 2 tracks), Air: 1 play but the most recent.
    play_fixture(alice, %{"track" => "Time", "timestamp" => t})
    play_fixture(alice, %{"track" => "Money", "timestamp" => t + 1})
    play_fixture(bob, %{"track" => "Time", "timestamp" => t + 2})

    play_fixture(bob, %{
      "artist" => "Air",
      "track" => "Sexy Boy",
      "album" => "Moon Safari",
      "timestamp" => t + 100
    })

    %{alice: alice, bob: bob, everyone: Charts.audience(alice)}
  end

  test "artists with their numbers, most played first", %{everyone: everyone} do
    assert [
             %{artist: %{name: "Pink Floyd"}, plays: 3, listeners: 2, tracks: 2, albums: 1} =
               floyd,
             %{artist: %{name: "Air"}, plays: 1, listeners: 1}
           ] = Charts.library_artists(everyone)

    assert floyd.first == ~U[2026-11-01 12:00:00Z]
    assert floyd.last == ~U[2026-11-01 12:00:02Z]
  end

  test "albums carry their artist", %{everyone: everyone} do
    assert [
             %{
               album: %{title: "The Dark Side of the Moon", artist: %{name: "Pink Floyd"}},
               plays: 3,
               tracks: 2
             },
             %{album: %{title: "Moon Safari", artist: %{name: "Air"}}}
           ] = Charts.library_albums(everyone)
  end

  test "sorts by name and by most recent", %{everyone: everyone} do
    assert ["Air", "Pink Floyd"] =
             everyone |> Charts.library_artists(sort: :name) |> Enum.map(& &1.artist.name)

    assert ["Air", "Pink Floyd"] =
             everyone |> Charts.library_artists(sort: :recent) |> Enum.map(& &1.artist.name)

    assert Charts.parse_sort("recent") == :recent
    assert Charts.parse_sort("drop table") == :plays
  end

  test "search: any case, album title or artist, wildcards taken literally", %{
    alice: alice,
    everyone: everyone
  } do
    assert [%{artist: %{name: "Air"}}] = Charts.library_artists(everyone, search: "aI")
    assert [%{album: %{title: "Moon Safari"}}] = Charts.library_albums(everyone, search: "safari")
    assert [%{album: %{title: "Moon Safari"}}] = Charts.library_albums(everyone, search: "air")
    assert [_, _] = Charts.library_albums(everyone, search: "moon")
    assert [] = Charts.library_artists(everyone, search: "%")

    play_fixture(alice, %{"artist" => "100% Pure", "track" => "x"})
    assert [%{artist: %{name: "100% Pure"}}] = Charts.library_artists(everyone, search: "0%")
  end

  test "paging", %{everyone: everyone} do
    assert [%{artist: %{name: "Pink Floyd"}}] = Charts.library_artists(everyone, limit: 1)
    assert [%{artist: %{name: "Air"}}] = Charts.library_artists(everyone, limit: 1, offset: 1)
  end

  test "stats: how many match, and the most plays among them", %{everyone: everyone} do
    assert %{count: 2, max_plays: 3} = Charts.library_stats(:artists, everyone)
    assert %{count: 1, max_plays: 1} = Charts.library_stats(:albums, everyone, search: "safari")
    assert %{count: 0, max_plays: 0} = Charts.library_stats(:albums, everyone, search: "nothing")
  end

  test "me, and others' private plays", %{alice: alice, bob: bob} do
    assert [%{artist: %{name: "Pink Floyd"}, plays: 2}] =
             Charts.library_artists(Charts.audience(alice, alice))

    :ok = Privacy.mark(bob, Catalog.ensure_artist!("Air"))
    assert [%{artist: %{name: "Pink Floyd"}}] = Charts.library_artists(Charts.audience(alice))
    assert %{count: 0} = Charts.library_stats(:albums, Charts.audience(alice), search: "safari")
    assert [_, _] = Charts.library_artists(Charts.audience(bob))
  end
end

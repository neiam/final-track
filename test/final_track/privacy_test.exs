defmodule FinalTrack.PrivacyTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Catalog, Charts, Privacy, Scrobbles}
  alias FinalTrack.Charts.Period

  @week Period.containing(:week, ~D[2026-11-17])

  setup do
    alice = user_fixture()
    bob = user_fixture()
    at = unix("2026-11-17T12:00:00Z")

    play_fixture(alice, %{"track" => "Time", "timestamp" => at})
    play_fixture(alice, %{"track" => "Money", "timestamp" => at + 1})

    play_fixture(alice, %{
      "artist" => "Air",
      "track" => "Sexy Boy",
      "album" => "Moon Safari",
      "timestamp" => at + 2
    })

    artist = Catalog.ensure_artist!("Pink Floyd")

    %{
      alice: alice,
      bob: bob,
      artist: artist,
      album: Catalog.ensure_album!(artist, "The Dark Side of the Moon"),
      time: Catalog.ensure_track!(artist, "Time")
    }
  end

  defp seen_by(viewer, owner \\ nil),
    do: Charts.total_plays(@week, "Etc/UTC", Charts.audience(viewer, owner))

  test "a private track hides only that track's plays, from others only", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.time)

    assert seen_by(ctx.bob) == 2
    assert seen_by(ctx.alice) == 3
    assert seen_by(ctx.alice, ctx.alice) == 3

    refute Enum.any?(
             Charts.top_tracks(@week, "Etc/UTC", Charts.audience(ctx.bob)),
             &(&1.track.title == "Time")
           )
  end

  test "a private album or artist hides everything under it", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.album)
    assert seen_by(ctx.bob) == 1

    :ok = Privacy.unmark(ctx.alice, ctx.album)
    :ok = Privacy.mark(ctx.alice, ctx.artist)
    assert seen_by(ctx.bob) == 1

    assert [%{artist: %{name: "Air"}}] =
             Charts.top_artists(@week, "Etc/UTC", Charts.audience(ctx.bob))

    assert %{plays: 0, listeners: 0} = Charts.summary(ctx.artist, Charts.audience(ctx.bob))
    assert %{plays: 2} = Charts.summary(ctx.artist, Charts.audience(ctx.alice))
  end

  test "it's per user: bob's own plays of the same artist stay visible", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.artist)
    play_fixture(ctx.bob, %{"timestamp" => unix("2026-11-17T13:00:00Z")})

    assert seen_by(ctx.alice) == 4
    assert seen_by(ctx.bob) == 2
  end

  test "unmarking brings the history back; marking twice is fine", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.time)
    :ok = Privacy.mark(ctx.alice, ctx.time)
    assert [_] = Privacy.list_marks(ctx.alice)
    assert seen_by(ctx.bob) == 2

    [mark] = Privacy.list_marks(ctx.alice)
    assert {:error, :not_found} = Privacy.delete_mark(ctx.bob, mark.id)
    assert :ok = Privacy.delete_mark(ctx.alice, mark.id)
    assert seen_by(ctx.bob) == 3
  end

  test "latest plays and listening now leave others' private listening out", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.artist)

    assert Enum.all?(Scrobbles.recent(Charts.audience(ctx.bob)), &(&1.artist_id != ctx.artist.id))
    assert length(Scrobbles.recent(Charts.audience(ctx.alice))) == 3

    {:ok, play} = Scrobbles.validate_play(%{"artist" => "Pink Floyd", "track" => "Time"})
    :ok = Scrobbles.set_now_playing(ctx.alice, play)

    assert Scrobbles.now_playing(ctx.bob) == []
    assert [_] = Scrobbles.now_playing(ctx.alice)
  end

  test "an album only listened to privately isn't listed on the artist page for others", ctx do
    :ok = Privacy.mark(ctx.alice, ctx.album)
    assert Charts.artist_albums(ctx.artist, Charts.audience(ctx.bob)) == []
    assert [_] = Charts.artist_albums(ctx.artist, Charts.audience(ctx.alice))
  end
end

defmodule FinalTrack.Catalog.RepairTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures

  alias FinalTrack.Catalog.{Album, Artist, Repair, Track}
  alias FinalTrack.{Repo, Scrobbles}
  alias FinalTrack.Scrobbles.{PrivateMark, Scrobble}

  @tangled "Cage The Elephant • Tell Me I'm Pretty • YouTube Music"

  # Plays as they were recorded before validate_play untangled the name.
  defp play(artist, track, at, album \\ nil) do
    %{
      artist: artist,
      track: track,
      album: album,
      album_artist: nil,
      duration_sec: 200,
      played_at: DateTime.from_unix!(at)
    }
  end

  test "moves plays, albums and marks onto the real artist and deletes the tangled one" do
    user = user_fixture()
    other = user_fixture()

    Scrobbles.record_plays(user, [
      play(@tangled, "Cry Baby", 1_000),
      play(@tangled, "Mess Around", 2_000),
      # Already recorded correctly at the same moment: a duplicate.
      play("Cage The Elephant", "Mess Around", 2_000, "Tell Me I'm Pretty")
    ])

    Scrobbles.record_plays(other, [play(@tangled, "Cry Baby", 3_000, "Sent Album")])

    bad = Repo.get_by!(Artist, name: @tangled)
    bad_track = Repo.get_by!(Track, artist_id: bad.id, title: "Cry Baby")
    Repo.insert!(%PrivateMark{user_id: user.id, track_id: bad_track.id})

    assert [
             "\"Cage The Elephant • Tell Me I'm Pretty • YouTube Music\" → \"Cage The Elephant\"" <>
               _
           ] =
             Repair.run()

    assert Repo.get(Artist, bad.id), "a dry run changes nothing"

    assert [line] = Repair.run(apply: true)
    assert line =~ "moved 2, dropped 1"

    refute Repo.get(Artist, bad.id)
    real = Repo.get_by!(Artist, name: "Cage The Elephant")
    album = Repo.get_by!(Album, artist_id: real.id, title: "Tell Me I'm Pretty")

    plays = Repo.all(from s in Scrobble, preload: [:track, :album])
    assert length(plays) == 3
    assert Enum.all?(plays, &(&1.artist_id == real.id))

    by_user = Enum.filter(plays, &(&1.user_id == user.id))
    assert Enum.all?(by_user, &(&1.album_id == album.id))
    # A play that named its own album keeps it (moved under the real artist).
    [theirs] = Enum.filter(plays, &(&1.user_id == other.id))
    assert theirs.album.title == "Sent Album" and theirs.album.artist_id == real.id

    real_track = Repo.get_by!(Track, artist_id: real.id, title: "Cry Baby")
    assert Repo.get_by!(PrivateMark, user_id: user.id).track_id == real_track.id

    assert Repair.run(apply: true) == ["nothing to repair"]
  end
end

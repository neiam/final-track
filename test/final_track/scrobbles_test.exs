defmodule FinalTrack.ScrobblesTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Repo, Scrobbles}
  alias FinalTrack.Scrobbles.{NowPlaying, Scrobble}

  describe "validate_play/1" do
    test "picks out and cleans the fields" do
      assert {:ok, play} =
               Scrobbles.validate_play(%{
                 "artist" => "  Air\u0007 ",
                 "track" => "La femme d'argent",
                 "album" => "",
                 "albumArtist" => "Air",
                 "durationSec" => 429,
                 "who" => "someone else"
               })

      assert play.artist == "Air"
      assert play.album == nil
      assert play.album_artist == "Air"
      assert play.duration_sec == 429
      refute Map.has_key?(play, :who)
    end

    test "refuses a missing, blank, non-string or overlong field" do
      assert {:error, "artist: is required"} = Scrobbles.validate_play(%{"track" => "x"})

      assert {:error, "track: must not be blank"} =
               Scrobbles.validate_play(%{"artist" => "a", "track" => " "})

      assert {:error, "track: must be a string"} =
               Scrobbles.validate_play(%{"artist" => "a", "track" => 1})

      assert {:error, "album: must be at most 256 characters"} =
               Scrobbles.validate_play(%{
                 "artist" => "a",
                 "track" => "t",
                 "album" => String.duplicate("x", 257)
               })

      assert {:error, _} = Scrobbles.validate_play(["not", "a", "map"])
    end

    test "takes a sane timestamp, and stamps now for a future or garbage one" do
      ts = System.os_time(:second) - 3600

      assert {:ok, %{played_at: at}} =
               Scrobbles.validate_play(%{"artist" => "a", "track" => "t", "timestamp" => ts})

      assert DateTime.to_unix(at) == ts

      for bad <- [System.os_time(:second) + 86_400, 12, "yesterday"] do
        {:ok, %{played_at: at}} =
          Scrobbles.validate_play(%{"artist" => "a", "track" => "t", "timestamp" => bad})

        assert abs(DateTime.diff(at, DateTime.utc_now())) < 5
      end
    end
  end

  describe "record_plays/2" do
    test "the same play twice is one scrobble (client retries)" do
      user = user_fixture()
      ts = System.os_time(:second) - 60
      {:ok, play} = Scrobbles.validate_play(%{"artist" => "a", "track" => "t", "timestamp" => ts})

      assert Scrobbles.record_plays(user, [play, play]) == 1
      assert Scrobbles.record_plays(user, [play]) == 0
      assert Repo.aggregate(Scrobble, :count) == 1
    end

    test "the album goes under the album artist when one is sent" do
      user = user_fixture()

      play_fixture(user, %{
        "artist" => "Guest Singer",
        "track" => "Duet",
        "album" => "Compilation",
        "albumArtist" => "Various Artists"
      })

      [s] = Scrobbles.recent(FinalTrack.Charts.audience(user))
      assert s.track.artist.name == "Guest Singer"
      assert s.album.artist.name == "Various Artists"
    end

    test "is broadcast" do
      Scrobbles.subscribe()
      user = user_fixture()
      play_fixture(user)
      user_id = user.id
      assert_receive {:scrobbled, ^user_id, 1}
    end
  end

  describe "tokens" do
    test "verify by the plaintext only, and revoke" do
      user = user_fixture()
      {plaintext, token} = token_fixture(user)

      assert {:ok, verified} = Scrobbles.verify_token(plaintext)
      assert verified.id == user.id
      assert Repo.reload(token).last_used_at
      assert :error = Scrobbles.verify_token("nope")
      assert :error = Scrobbles.verify_token(Base.url_encode64(token.token_hash, padding: false))

      assert {:error, :not_found} = Scrobbles.revoke_token(user_fixture(), token.id)
      assert :ok = Scrobbles.revoke_token(user, token.id)
      assert :error = Scrobbles.verify_token(plaintext)
    end
  end

  describe "now playing" do
    test "one row per user, gone once it expires" do
      user = user_fixture()

      {:ok, play} =
        Scrobbles.validate_play(%{"artist" => "a", "track" => "one", "durationSec" => 100})

      :ok = Scrobbles.set_now_playing(user, play)

      {:ok, play} =
        Scrobbles.validate_play(%{"artist" => "a", "track" => "two", "durationSec" => 100})

      :ok = Scrobbles.set_now_playing(user, play)

      assert [%{track: %{title: "two"}}] = Scrobbles.now_playing(user)

      Repo.update_all(NowPlaying, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])
      assert Scrobbles.now_playing(user) == []
    end
  end
end

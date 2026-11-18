defmodule FinalTrack.FederationTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures
  import FinalTrack.FederationHelpers

  alias FinalTrack.{Catalog, Covers, Federation, Privacy, Repo}
  alias FinalTrack.Federation.{Follower, Post}

  setup do
    user = user_fixture()
    account = fedi_account(user)
    bob = remote_actor()
    stub_remote([bob])

    Repo.insert!(%Follower{
      account_id: account.id,
      actor_id: bob.id,
      inbox: bob.inbox,
      shared_inbox: bob.shared_inbox
    })

    %{user: user, account: account, bob: bob}
  end

  defp with_cover(album_title \\ "The Dark Side of the Moon") do
    artist = Catalog.ensure_artist!("Pink Floyd")
    album = artist |> Catalog.ensure_album!(album_title) |> Map.put(:artist, artist)
    path = Path.join(System.tmp_dir!(), "cover-#{System.unique_integer([:positive])}")
    File.write!(path, png_bytes())
    {:ok, album} = Covers.put_upload(album, path)
    album
  end

  test "a new play is posted to followers, signed, with its cover attached",
       %{user: user, account: account, bob: bob} do
    album = with_cover()
    play_fixture(user)

    assert_received {:delivered, inbox, activity, headers, body, path}
    # Delivered to the shared inbox when the follower has one.
    assert inbox == bob.shared_inbox
    assert_signed_by(account, headers, body, path)

    assert %{"type" => "Create", "actor" => actor, "object" => note} = activity
    assert actor =~ "/ap/users/alice"
    assert note["type"] == "Note"
    assert note["content"] =~ "<strong>Time</strong> by Pink Floyd"
    assert note["content"] =~ "The Dark Side of the Moon"
    # Unlisted.
    assert note["to"] == [actor <> "/followers"]
    assert note["cc"] == ["https://www.w3.org/ns/activitystreams#Public"]

    assert [%{"type" => "Document", "mediaType" => "image/png", "url" => url, "name" => alt}] =
             note["attachment"]

    assert url =~ "/covers/#{album.id}?v="
    assert alt == "Cover of The Dark Side of the Moon by Pink Floyd"
  end

  test "public accounts address everyone, with followers in cc", %{user: user, account: account} do
    {:ok, _} = Federation.save_account(user, %{visibility: "public"})
    play_fixture(user)

    assert_received {:delivered, _, %{"object" => note} = create, _, _, _}
    actor = FinalTrack.Federation.Objects.actor_url(account)
    assert note["to"] == ["https://www.w3.org/ns/activitystreams#Public"]
    assert note["cc"] == [actor <> "/followers"]
    assert create["to"] == note["to"]
  end

  test "each post has its own url (Pixelfed drops posts that share one)", %{user: user} do
    play_fixture(user, %{"timestamp" => System.os_time(:second) - 120})
    play_fixture(user, %{"track" => "Money"})

    assert_received {:delivered, _, %{"object" => %{"id" => id1, "url" => url1}}, _, _, _}
    assert_received {:delivered, _, %{"object" => %{"id" => id2, "url" => url2}}, _, _, _}
    assert url1 == id1
    assert url2 == id2
    refute url1 == url2
  end

  test "visibility must be one we know", %{user: user} do
    assert {:error, cs} = Federation.save_account(user, %{visibility: "everyone"})
    assert "is invalid" in errors_on(cs).visibility
  end

  test "no cover, no attachment", %{user: user} do
    play_fixture(user)
    assert_received {:delivered, _, %{"object" => %{"attachment" => []}}, _, _, _}
  end

  test "private plays, old plays and switched-off accounts aren't posted", %{user: user} do
    :ok = Privacy.mark(user, Catalog.ensure_artist!("Pink Floyd"))
    play_fixture(user)
    refute_received {:delivered, _, _, _, _, _}

    play_fixture(user, %{
      "artist" => "Air",
      "track" => "Sexy Boy",
      "timestamp" => System.os_time(:second) - 7 * 3600
    })

    refute_received {:delivered, _, _, _, _, _}

    {:ok, _} = Federation.save_account(user, %{enabled: false})
    play_fixture(user, %{"artist" => "Air", "track" => "Kelly Watch the Stars"})
    refute_received {:delivered, _, _, _, _, _}
    assert Repo.aggregate(Post, :count) == 0
  end

  test "a retried batch isn't posted twice", %{user: user} do
    ts = System.os_time(:second) - 60
    play_fixture(user, %{"timestamp" => ts})
    play_fixture(user, %{"timestamp" => ts})

    assert_received {:delivered, _, _, _, _, _}
    refute_received {:delivered, _, _, _, _, _}
  end

  test "marking something private withdraws what was posted", %{user: user, account: account} do
    play_fixture(user)
    assert_received {:delivered, _, %{"object" => %{"id" => note_id}}, _, _, _}
    [post] = Repo.all(Post)
    assert {:ok, _} = Federation.get_post(post.id)

    :ok =
      Privacy.mark(
        user,
        Catalog.ensure_album!(Catalog.ensure_artist!("Pink Floyd"), "The Dark Side of the Moon")
      )

    assert_received {:delivered, _,
                     %{
                       "type" => "Delete",
                       "object" => %{"id" => ^note_id, "type" => "Tombstone"}
                     }, headers, body, path}

    assert_signed_by(account, headers, body, path)
    assert Repo.all(Post) == []
  end

  test "titles are escaped in the post", %{user: user} do
    play_fixture(user, %{"artist" => "<script>", "track" => "a & b", "album" => nil})
    assert_received {:delivered, _, %{"object" => %{"content" => content}}, _, _, _}
    assert content =~ "&lt;script&gt;"
    assert content =~ "a &amp; b"
    refute content =~ "<script>"
  end

  test "usernames: Mastodon's rules, unique, reserved names refused", %{user: user} do
    other = user_fixture()
    assert {:error, cs} = Federation.save_account(other, %{username: "alice"})
    assert "has already been taken" in errors_on(cs).username
    assert {:error, cs} = Federation.save_account(other, %{username: "Bad Name!"})
    assert errors_on(cs).username != []
    assert {:error, _} = Federation.save_account(other, %{username: "admin"})
    assert {:ok, %{username: "carol"}} = Federation.save_account(other, %{username: "@Carol"})

    # The key pair is made once and kept.
    account = Federation.get_account(user)
    {:ok, renamed} = Federation.save_account(user, %{username: "alice2"})
    assert renamed.private_key_pem == account.private_key_pem
  end
end

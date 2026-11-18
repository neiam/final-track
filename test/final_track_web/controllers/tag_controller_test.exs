defmodule FinalTrackWeb.TagControllerTest do
  use FinalTrackWeb.ConnCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures
  import FinalTrack.FederationHelpers

  alias FinalTrack.{Catalog, Federation, Privacy}

  setup do
    stub_remote([])
    alice = user_fixture()

    {:ok, _} =
      Federation.save_account(alice, %{username: "alice", enabled: true, visibility: "public"})

    %{alice: alice}
  end

  defp tagged(tag), do: tag |> Federation.tagged_posts() |> Enum.map(& &1.scrobble.track.title)

  test "a public account's posts are under its hashtag, any case", %{conn: conn, alice: alice} do
    play_fixture(alice)

    assert tagged("scropple") == ["Time"]
    assert tagged("#Scropple") == ["Time"]

    doc = conn |> get("/tags/scropple") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(doc, "#tag-name") |> LazyHTML.text() =~ "#scropple"
    posts = LazyHTML.query(doc, "#tag-posts") |> LazyHTML.text()
    assert posts =~ "Time"
    assert posts =~ "@alice"
  end

  test "artist tags only for accounts that tag artists", %{alice: alice} do
    play_fixture(alice)
    assert tagged("pinkfloyd") == []

    {:ok, _} = Federation.save_account(alice, %{tag_artist: true})
    play_fixture(alice, %{"track" => "Money"})
    # Earlier posts count too: the switch says what the account tags.
    assert tagged("pinkfloyd") == ["Money", "Time"]
  end

  test "unlisted accounts and private plays stay off", %{alice: alice} do
    bob = user_fixture()
    {:ok, _} = Federation.save_account(bob, %{username: "bob", enabled: true})
    play_fixture(bob, %{"artist" => "Air", "track" => "Sexy Boy"})
    play_fixture(alice, %{"artist" => "Air", "track" => "Kelly Watch the Stars"})
    assert tagged("scropple") == ["Kelly Watch the Stars"]

    :ok = Privacy.mark(alice, Catalog.ensure_artist!("Air"))
    assert tagged("scropple") == []
  end

  test "an unknown tag is an empty page", %{conn: conn} do
    doc = conn |> get("/tags/nothinghere") |> html_response(200) |> LazyHTML.from_document()
    refute Enum.empty?(LazyHTML.query(doc, "#tag-empty"))
  end

  test "new artists get their tag" do
    assert %{tag: "sigurrós"} = Catalog.ensure_artist!("Sigur Rós")
    assert %{tag: nil} = Catalog.ensure_artist!("311")
  end
end

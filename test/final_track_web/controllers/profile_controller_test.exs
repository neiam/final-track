defmodule FinalTrackWeb.ProfileControllerTest do
  use FinalTrackWeb.ConnCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures
  import FinalTrack.FederationHelpers

  alias FinalTrack.{Catalog, Federation, Privacy}
  alias FinalTrack.Federation.Objects

  setup do
    user = user_fixture()
    {:ok, user} = FinalTrack.Accounts.update_user_profile(user, %{display_name: "Alice"})
    account = fedi_account(user)
    play_fixture(user)
    play_fixture(user, %{"artist" => "Air", "track" => "Sexy Boy", "album" => "Moon Safari"})
    %{user: user, account: account}
  end

  test "a browser gets the profile page, with the recent plays", %{conn: conn} do
    doc = conn |> get("/@alice") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "#profile-name") |> LazyHTML.text() =~ "Alice"
    assert LazyHTML.query(doc, "#profile-handle") |> LazyHTML.text() =~ "@alice@localhost"
    plays = LazyHTML.query(doc, "#profile-plays") |> LazyHTML.text()
    assert plays =~ "Time"
    assert plays =~ "Sexy Boy"
  end

  test "the username is case-insensitive", %{conn: conn} do
    assert html_response(get(conn, "/@Alice"), 200)
  end

  test "a fediverse server gets the actor document", %{conn: conn, account: account} do
    doc =
      conn
      |> put_req_header(
        "accept",
        ~s(application/ld+json; profile="https://www.w3.org/ns/activitystreams")
      )
      |> get("/@alice")
      |> json_response(200)

    assert doc["id"] == Objects.actor_url(account)
    assert doc["url"] == Objects.profile_url(account)
    assert doc["publicKey"]["publicKeyPem"] == account.public_key_pem
  end

  test "private plays aren't on it", %{conn: conn, user: user} do
    :ok = Privacy.mark(user, Catalog.ensure_artist!("Air"))
    html = conn |> get("/@alice") |> html_response(200)
    assert html =~ "Time"
    refute html =~ "Sexy Boy"
  end

  test "no such account, or switched off: 404", %{conn: conn, user: user} do
    assert html_response(get(conn, "/@nobody"), 404)

    assert response(
             conn |> put_req_header("accept", "application/activity+json") |> get("/@nobody"),
             404
           )

    {:ok, _} = Federation.save_account(user, %{enabled: false})
    assert html_response(get(conn, "/@alice"), 404)
  end
end

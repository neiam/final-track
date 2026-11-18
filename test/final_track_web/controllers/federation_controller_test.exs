defmodule FinalTrackWeb.FederationControllerTest do
  use FinalTrackWeb.ConnCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures
  import FinalTrack.FederationHelpers

  alias FinalTrack.{Catalog, Federation, Privacy, Repo}
  alias FinalTrack.Federation.{Follower, Objects, Post}

  setup do
    user = user_fixture()
    account = fedi_account(user)
    %{user: user, account: account, actor_url: Objects.actor_url(account)}
  end

  defp ap(conn), do: put_req_header(conn, "accept", "application/activity+json")

  describe "discovery" do
    test "webfinger by acct or actor URL", %{conn: conn, actor_url: actor_url} do
      for resource <- ["acct:alice@localhost", actor_url] do
        conn = get(conn, ~p"/.well-known/webfinger?#{[resource: resource]}")
        assert %{"subject" => "acct:alice@localhost", "links" => links} = json_response(conn, 200)
        assert %{"href" => ^actor_url} = Enum.find(links, &(&1["rel"] == "self"))
      end

      assert response(get(conn, ~p"/.well-known/webfinger?resource=acct:nobody@localhost"), 404)

      assert response(
               get(conn, ~p"/.well-known/webfinger?resource=acct:alice@elsewhere.example"),
               404
             )

      assert response(get(conn, ~p"/.well-known/webfinger"), 400)

      conn = get(conn, ~p"/.well-known/webfinger?resource=acct:localhost@localhost")
      assert %{"aliases" => [instance]} = json_response(conn, 200)
      assert instance =~ "/ap/actor"
    end

    test "a switched-off account isn't there", %{conn: conn, user: user} do
      {:ok, _} = Federation.save_account(user, %{enabled: false})
      assert response(get(conn, ~p"/.well-known/webfinger?resource=acct:alice@localhost"), 404)
      assert response(conn |> ap() |> get(~p"/ap/users/alice"), 404)
    end

    test "nodeinfo", %{conn: conn} do
      assert %{"links" => [%{"href" => href}]} =
               json_response(get(conn, ~p"/.well-known/nodeinfo"), 200)

      assert href =~ "/nodeinfo/2.0"

      assert %{
               "software" => %{"name" => "final_track"},
               "protocols" => ["activitypub"],
               "usage" => %{"users" => %{"total" => 1}}
             } =
               json_response(get(conn, ~p"/nodeinfo/2.0"), 200)
    end

    test "the account's actor, with its key", %{
      conn: conn,
      account: account,
      actor_url: actor_url
    } do
      doc = conn |> ap() |> get(~p"/ap/users/alice") |> json_response(200)

      assert %{"id" => ^actor_url, "type" => "Service", "preferredUsername" => "alice"} = doc
      assert doc["url"] == FinalTrackWeb.base_url() <> "/@alice"

      assert doc["publicKey"] == %{
               "id" => actor_url <> "#main-key",
               "owner" => actor_url,
               "publicKeyPem" => account.public_key_pem
             }

      assert doc["endpoints"]["sharedInbox"] =~ "/ap/inbox"
      refute Map.has_key?(doc, "privateKeyPem")
    end

    test "a browser on the actor URL is sent to the profile", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/ap/users/alice")) ==
               FinalTrackWeb.base_url() <> "/@alice"
    end

    test "webfinger takes every way people and servers write it", %{
      conn: conn,
      actor_url: actor_url
    } do
      base = FinalTrackWeb.base_url()

      for resource <- [
            "acct:alice@localhost",
            "acct:@alice@localhost",
            "acct:ALICE@LocalHost",
            "  acct:alice@localhost ",
            actor_url,
            base <> "/@alice",
            base <> "/@Alice"
          ] do
        conn = get(conn, ~p"/.well-known/webfinger?#{[resource: resource]}")

        assert %{"subject" => "acct:alice@localhost", "aliases" => aliases, "links" => links} =
                 json_response(conn, 200),
               resource

        assert get_resp_header(conn, "content-type") |> hd() =~ "application/jrd+json"
        assert (base <> "/@alice") in aliases

        assert %{"href" => profile} =
                 Enum.find(links, &(&1["rel"] == "http://webfinger.net/rel/profile-page"))

        assert profile == base <> "/@alice"
      end

      for resource <- [
            "acct:alice@elsewhere.example",
            "https://elsewhere.example/@alice",
            base <> "/@",
            "alice",
            "acct:"
          ] do
        assert response(get(conn, ~p"/.well-known/webfinger?#{[resource: resource]}"), 404),
               resource
      end
    end

    test "host-meta points at webfinger", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/host-meta")
      body = response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xrd+xml"
      assert body =~ ~s(rel="lrdd")
      assert body =~ FinalTrackWeb.base_url() <> "/.well-known/webfinger?resource={uri}"
    end

    test "the instance actor", %{conn: conn} do
      assert %{
               "type" => "Application",
               "publicKey" => %{"publicKeyPem" => "-----BEGIN PUBLIC KEY" <> _}
             } =
               conn |> ap() |> get(~p"/ap/actor") |> json_response(200)
    end
  end

  describe "posts" do
    test "a note is served while its play may be shown, then gone", %{conn: conn, user: user} do
      play_fixture(user)
      [post] = Repo.all(Post)

      assert %{"type" => "Note", "content" => content} =
               conn |> ap() |> get(~p"/ap/notes/#{post.id}") |> json_response(200)

      assert content =~ "Time"

      assert %{"totalItems" => 1, "orderedItems" => [%{"type" => "Create"}]} =
               conn |> ap() |> get(~p"/ap/users/alice/outbox") |> json_response(200)

      :ok = Privacy.mark(user, Catalog.ensure_artist!("Pink Floyd"))
      # Withdrawn and forgotten.
      assert response(conn |> ap() |> get(~p"/ap/notes/#{post.id}"), 404)
      assert response(conn |> ap() |> get(~p"/ap/notes/#{Ecto.UUID.generate()}"), 404)
    end

    test "followers: a count, never the list", %{conn: conn, account: account} do
      Repo.insert!(%Follower{
        account_id: account.id,
        actor_id: "https://remote.example/users/x",
        inbox: "https://remote.example/users/x/inbox"
      })

      doc = conn |> ap() |> get(~p"/ap/users/alice/followers") |> json_response(200)
      assert doc["totalItems"] == 1
      refute Map.has_key?(doc, "orderedItems")
    end
  end

  describe "inbox" do
    setup do
      bob = remote_actor()
      stub_remote([bob])
      %{bob: bob}
    end

    defp follow(bob, actor_url) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => bob.id <> "#follows/1",
        "type" => "Follow",
        "actor" => bob.id,
        "object" => actor_url
      }
    end

    defp post_signed(conn, path, activity, signer) do
      body = Jason.encode!(activity)

      conn
      |> Plug.Conn.merge_req_headers(signed_headers(signer, path, body))
      |> post(path, body)
    end

    test "a signed Follow is accepted, and answered with a signed Accept",
         %{conn: conn, bob: bob, account: account, actor_url: actor_url} do
      activity = follow(bob, actor_url)
      conn = post_signed(conn, "/ap/users/alice/inbox", activity, bob)
      assert response(conn, 202)

      assert [%Follower{actor_id: actor_id, shared_inbox: shared}] = Repo.all(Follower)
      assert actor_id == bob.id
      assert shared == bob.shared_inbox

      assert_received {:delivered, inbox, %{"type" => "Accept", "object" => accepted}, headers,
                       body, path}

      assert inbox == bob.inbox
      assert accepted["id"] == activity["id"]
      assert_signed_by(account, headers, body, path)
    end

    test "the shared inbox works too, and Undo unfollows", %{
      conn: conn,
      bob: bob,
      actor_url: actor_url
    } do
      activity = follow(bob, actor_url)
      assert response(post_signed(conn, "/ap/inbox", activity, bob), 202)
      assert [_] = Repo.all(Follower)

      undo = %{
        "id" => bob.id <> "#undo/1",
        "type" => "Undo",
        "actor" => bob.id,
        "object" => activity
      }

      assert response(post_signed(build_conn(), "/ap/inbox", undo, bob), 202)
      assert Repo.all(Follower) == []
    end

    test "unsigned, badly signed or someone else's signature: 401", %{
      conn: conn,
      bob: bob,
      actor_url: actor_url
    } do
      activity = follow(bob, actor_url)
      body = Jason.encode!(activity)

      assert response(
               conn
               |> put_req_header("content-type", "application/activity+json")
               |> post("/ap/inbox", body),
               401
             )

      # Signed over a different body.
      tampered = Jason.encode!(%{activity | "id" => bob.id <> "#follows/2"})

      conn =
        build_conn()
        |> Plug.Conn.merge_req_headers(signed_headers(bob, "/ap/inbox", body))
        |> post("/ap/inbox", tampered)

      assert response(conn, 401)

      # Mallory signs properly, but claims to be Bob.
      mallory = remote_actor("mallory")
      stub_remote([bob, mallory])
      assert response(post_signed(build_conn(), "/ap/inbox", activity, mallory), 401)

      assert Repo.all(Follower) == []
    end

    test "a Delete of an actor that's gone drops it as a follower", %{
      conn: conn,
      bob: bob,
      account: account
    } do
      Repo.insert!(%Follower{account_id: account.id, actor_id: bob.id, inbox: bob.inbox})
      stub_remote([], gone: [bob.id])

      delete = %{
        "id" => bob.id <> "#delete",
        "type" => "Delete",
        "actor" => bob.id,
        "object" => bob.id
      }

      body = Jason.encode!(delete)

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/ap/inbox", body)

      assert response(conn, 202)
      assert Repo.all(Follower) == []
    end

    test "a Delete of an actor that's still there changes nothing", %{
      conn: conn,
      bob: bob,
      account: account
    } do
      Repo.insert!(%Follower{account_id: account.id, actor_id: bob.id, inbox: bob.inbox})

      delete = %{
        "id" => bob.id <> "#delete",
        "type" => "Delete",
        "actor" => bob.id,
        "object" => bob.id
      }

      conn =
        conn
        |> put_req_header("content-type", "application/activity+json")
        |> post("/ap/inbox", Jason.encode!(delete))

      assert response(conn, 202)
      assert [_] = Repo.all(Follower)
    end

    test "an unknown account's inbox is 404", %{conn: conn, bob: bob} do
      assert response(post_signed(conn, "/ap/users/nobody/inbox", follow(bob, "x"), bob), 404)
    end
  end
end

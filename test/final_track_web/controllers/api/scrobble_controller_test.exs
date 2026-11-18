defmodule FinalTrackWeb.Api.ScrobbleControllerTest do
  use FinalTrackWeb.ConnCase, async: true

  import FinalTrack.AccountsFixtures
  import FinalTrack.ScrobblesFixtures

  alias FinalTrack.{Charts, Repo, Scrobbles}
  alias FinalTrack.Scrobbles.Scrobble

  setup %{conn: conn} do
    user = user_fixture()
    {token, _} = token_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    %{user: user, authed: authed}
  end

  # What Scropple's HttpBackend sends.
  defp track(overrides \\ %{}) do
    Map.merge(
      %{
        "artist" => "Pink Floyd",
        "track" => "Time",
        "album" => "The Dark Side of the Moon",
        "albumArtist" => nil,
        "durationSec" => 413,
        "timestamp" => System.os_time(:second) - 60
      },
      overrides
    )
  end

  defp post_json(conn, path, body), do: post(conn, path, Jason.encode!(body))

  describe "auth" do
    test "every bad token is the same 401", %{conn: conn} do
      for header <- [nil, "Bearer nope", "Basic abc", "Bearer "] do
        conn = if header, do: put_req_header(conn, "authorization", header), else: conn
        conn = post(conn, ~p"/api/v1/scrobble", %{})
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
      end
    end

    test "a revoked token stops working", %{user: user, conn: conn} do
      {token, record} = token_fixture(user)
      :ok = Scrobbles.revoke_token(user, record.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/api/v1/scrobble", %{})

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/scrobble" do
    test "takes a bare array (what Scropple sends)", %{authed: conn, user: user} do
      conn = post_json(conn, ~p"/api/v1/scrobble", [track(), track(%{"track" => "Money"})])
      assert json_response(conn, 200) == %{"accepted" => 2, "rejected" => 0}
      assert [_, _] = Scrobbles.recent(Charts.audience(user))
    end

    test "takes a single object or {scrobbles: [...]}", %{authed: conn} do
      assert %{"accepted" => 1} =
               conn |> post_json(~p"/api/v1/scrobble", track()) |> json_response(200)

      assert %{"accepted" => 1} =
               conn
               |> post_json(~p"/api/v1/scrobble", %{
                 "scrobbles" => [track(%{"track" => "Breathe"})]
               })
               |> json_response(200)
    end

    test "a retried batch adds nothing, but is still accepted", %{authed: conn} do
      batch = [track()]

      assert %{"accepted" => 1} =
               conn |> post_json(~p"/api/v1/scrobble", batch) |> json_response(200)

      assert %{"accepted" => 1} =
               conn |> post_json(~p"/api/v1/scrobble", batch) |> json_response(200)

      assert Repo.aggregate(Scrobble, :count) == 1
    end

    test "drops invalid plays from a batch; all invalid is a 422", %{authed: conn} do
      body = [track(), %{"artist" => "no track"}]

      assert %{"accepted" => 1, "rejected" => 1} =
               conn |> post_json(~p"/api/v1/scrobble", body) |> json_response(200)

      assert %{"error" => "invalid_payload", "detail" => "track: is required"} =
               conn |> post_json(~p"/api/v1/scrobble", [%{"artist" => "x"}]) |> json_response(422)
    end

    test "a client-supplied who can't scrobble as someone else", %{authed: conn, user: user} do
      other = user_fixture()

      conn
      |> post_json(~p"/api/v1/scrobble", track(%{"who" => other.email, "user_id" => other.id}))

      assert [%{user_id: id}] = Repo.all(Scrobble)
      assert id == user.id
    end
  end

  describe "POST /api/v1/now-playing" do
    test "sets what the user is listening to", %{authed: conn, user: user} do
      conn = post_json(conn, ~p"/api/v1/now-playing", track())
      assert response(conn, 204)
      assert [%{track: %{title: "Time"}}] = Scrobbles.now_playing(user)
    end

    test "422 for a bad body", %{authed: conn} do
      assert %{"error" => "invalid_payload"} =
               conn |> post_json(~p"/api/v1/now-playing", %{"track" => "x"}) |> json_response(422)
    end
  end
end

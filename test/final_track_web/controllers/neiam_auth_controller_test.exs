defmodule FinalTrackWeb.NeiamAuthControllerTest do
  @moduledoc """
  "Sign in with NEIAM" against neiam_auth's FakeIdP, through FinalTrack's own
  router, session and UserAuth.
  """
  use FinalTrackWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.{Accounts, Repo}
  alias NeiamAuth.Identity
  alias NeiamAuth.Test.FakeIdP

  @password "a good long password"

  setup %{conn: conn} do
    # NeiamAuth is config held in a persistent_term; put back the app's own
    # (disabled) config after each test.
    on_exit(fn -> NeiamAuth.put_config(NeiamAuth.Config.load(%{})) end)
    # /auth/oidc/* is served on the apex only, not on build_conn's
    # www.example.com.
    %{conn: conn}
  end

  defp app_conn, do: Phoenix.ConnTest.build_conn()

  defp idp(opts \\ []) do
    idp = FakeIdP.start(Keyword.take(opts, [:client_id, :user]))
    on_exit(fn -> FakeIdP.stop(idp) end)
    idp
  end

  defp neiam_env(idp, extra \\ []) do
    FakeIdP.env(
      idp,
      nil,
      [
        redirect_uri: "http://localhost:4002/auth/oidc/neiam/callback",
        scopes: "openid profile email groups",
        groups_claim: "groups",
        trust_email: "true",
        required_for_linked: "true",
        label: "Sign in with NEIAM"
      ] ++ extra
    )
  end

  defp start_neiam(env, ready \\ ["neiam"]) do
    start_supervised!(
      {NeiamAuth,
       env: Map.put_new(env, "OIDC_ENABLED", "true"),
       name: :neiam_auth_test,
       backoff_min: 50,
       backoff_max: 200}
    )

    Enum.each(ready, &wait_ready/1)
  end

  defp wait_ready(id, tries \\ 100) do
    {:ok, p} = NeiamAuth.config(id)

    cond do
      NeiamAuth.ready?(p) ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        wait_ready(id, tries - 1)

      true ->
        flunk("provider #{id} never loaded")
    end
  end

  # The browser's round trip: our login route, the IdP, our callback.
  defp sso(conn, idp, id, opts \\ []) do
    conn = get(conn, "/auth/oidc/#{id}/login", Keyword.get(opts, :query, %{}))
    params = FakeIdP.authorize(idp, redirected_to(conn, 302))
    params = Keyword.get(opts, :tamper, & &1).(params)
    conn |> recycle() |> get("/auth/oidc/#{Keyword.get(opts, :callback, id)}/callback", params)
  end

  defp signed_in_user(conn) do
    case get_session(conn, :user_token) do
      nil -> nil
      token -> with {user, _} <- Accounts.get_user_by_session_token(token), do: user
    end
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp password_log_in(email) do
    post(app_conn(), ~p"/users/log-in", %{
      "user" => %{"email" => email, "password" => valid_user_password()}
    })
  end

  describe "OIDC_ENABLED off (the default)" do
    test "no button, the routes 404, health says disabled", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      refute html =~ "/auth/oidc/"

      assert get(app_conn(), "/auth/oidc/neiam/login").status == 404

      assert get(app_conn(), "/auth/oidc/neiam/callback", %{code: "x", state: "y"}).status ==
               404

      assert %{"enabled" => false} =
               app_conn() |> get("/auth/oidc/health") |> json_response(200)
    end

    test "configured providers stay off without the switch", %{conn: conn} do
      idp = idp()

      start_supervised!({NeiamAuth, env: neiam_env(idp), name: :neiam_auth_test})

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      refute html =~ "Sign in with NEIAM"
      assert get(app_conn(), "/auth/oidc/neiam/login").status == 404
    end
  end

  describe "with NEIAM enabled" do
    setup do
      idp = idp()
      start_neiam(neiam_env(idp))
      %{idp: idp}
    end

    test "the log-in page shows the button as a plain link", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Sign in with NEIAM"
      assert html =~ ~s(href="/auth/oidc/neiam/login")
    end

    test "first login links an existing account by verified email", %{conn: conn, idp: idp} do
      user = user_fixture(email: "alice@example.com")

      conn = sso(conn, idp, "neiam")
      assert redirected_to(conn) == ~p"/"
      assert signed_in_user(conn).id == user.id

      assert [%Identity{sub: "fake-sub-1", provider: "neiam", groups: ["users"]} = identity] =
               Repo.all(Identity)

      assert identity.user_id == user.id

      # LiveView pages work on the new session.
      {:ok, _lv, _html} = conn |> recycle() |> live(~p"/users/settings")
    end

    test "an existing sub signs the same user in again", %{conn: conn, idp: idp} do
      user = user_fixture(email: "alice@example.com")
      sso(conn, idp, "neiam")

      FakeIdP.put_user(idp, email: "alice.renamed@example.com")
      conn = sso(app_conn(), idp, "neiam")
      assert signed_in_user(conn).id == user.id
      assert [%Identity{email: "alice.renamed@example.com"}] = Repo.all(Identity)
    end

    test "return_to is honoured, and only local paths", %{conn: conn, idp: idp} do
      user_fixture(email: "alice@example.com")
      conn = sso(conn, idp, "neiam", query: %{"return_to" => "/storefronts"})
      assert redirected_to(conn) == "/storefronts"

      conn = sso(app_conn(), idp, "neiam", query: %{"return_to" => "//evil.example/"})
      assert redirected_to(conn) == ~p"/"
    end

    test "state mismatch is refused", %{conn: conn, idp: idp} do
      user_fixture(email: "alice@example.com")
      conn = quietly(fn -> sso(conn, idp, "neiam", tamper: &Map.put(&1, "state", "forged")) end)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in failed"
      refute signed_in_user(conn)
    end

    test "expired state is refused" do
      {:ok, p} = NeiamAuth.config("neiam")
      entry = %{"provider" => "neiam", "state" => "s", "at" => System.system_time(:second) - 601}

      assert {:error, :state_expired} =
               NeiamAuth.Flow.finish(p, %{"state" => "s", "code" => "c"}, entry)
    end

    # final_track.neiam.co is another site than auth.neiam.org, so the callback
    # is a cross-site navigation. The flow state rides in the session cookie;
    # it must be SameSite=Lax (sent on a top-level cross-site GET), not
    # Strict (dropped), and host-only.
    test "the flow-state cookie survives the cross-site callback", %{idp: idp} do
      user = user_fixture(email: "alice@example.com")

      conn = get(app_conn(), "/auth/oidc/neiam/login")
      [cookie] = for {"set-cookie", v} <- conn.resp_headers, v =~ "_final_track_key=", do: v
      attrs = cookie |> String.split(";") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      assert "samesite=lax" in attrs
      refute Enum.any?(attrs, &String.starts_with?(&1, "domain="))

      # The callback carries nothing but that cookie, as a browser coming
      # back from the IdP would.
      params = FakeIdP.authorize(idp, redirected_to(conn, 302))
      callback = conn |> recycle() |> get("/auth/oidc/neiam/callback", params)
      assert signed_in_user(callback).id == user.id

      # Without it (what Strict would do) the login is refused.
      params = FakeIdP.authorize(idp, redirected_to(get(app_conn(), "/auth/oidc/neiam/login")))
      cookieless = quietly(fn -> get(app_conn(), "/auth/oidc/neiam/callback", params) end)
      refute signed_in_user(cookieless)
    end

    test "invite-only: no account means no sign-in, until an invite is accepted in this browser",
         %{conn: conn, idp: idp} do
      Application.put_env(:final_track, :registration_open, false)
      on_exit(fn -> Application.put_env(:final_track, :registration_open, true) end)

      conn = quietly(fn -> sso(conn, idp, "neiam") end)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invite"
      refute signed_in_user(conn)
      assert Repo.all(Identity) == []

      {:ok, invite} = Accounts.create_invite(user_fixture(), %{email: "new.person@example.com"})

      conn =
        conn
        |> recycle()
        |> post(~p"/users/register/invite", %{
          invite: invite.token,
          user: %{password: @password, password_confirmation: @password}
        })

      new_user = signed_in_user(conn)
      assert new_user.email == "new.person@example.com"
      assert [%Identity{sub: "fake-sub-1"} = identity] = Repo.all(Identity)
      assert identity.user_id == new_user.id

      # Next time NEIAM signs them straight in.
      conn = sso(app_conn(), idp, "neiam")
      assert signed_in_user(conn).id == new_user.id
    end

    test "password login still works for a linked account (Phase A)",
         %{conn: conn, idp: idp} do
      user = user_fixture(email: "alice@example.com") |> set_password()
      sso(conn, idp, "neiam")
      assert [_] = Repo.all(Identity)

      assert signed_in_user(password_log_in(user.email)).id == user.id
    end

    test "a signed-in user links the account from settings", %{conn: conn, idp: idp} do
      FakeIdP.put_user(idp, email: "someone.else@example.com")
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})

      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ ~s(href="/auth/oidc/neiam/login?link=1")

      conn = sso(conn, idp, "neiam", query: %{"link" => "1"})
      assert redirected_to(conn) == ~p"/users/settings"
      assert [%Identity{} = identity] = Repo.all(Identity)
      assert identity.user_id == user.id
    end
  end

  describe "PROVISION=auto" do
    setup do
      idp = idp()
      start_neiam(neiam_env(idp, provision: "auto"))
      %{idp: idp}
    end

    test "a member of other groups is no admin", %{conn: conn, idp: idp} do
      FakeIdP.put_user(idp, email: "member@example.com", groups: ["admins-not", "users"])
      user = conn |> sso(idp, "neiam") |> signed_in_user()
      refute FinalTrack.Accounts.get_user!(user.id).is_admin
    end

    test "a new account is confirmed, passwordless, named from the IdP",
         %{conn: conn, idp: idp} do
      FakeIdP.put_user(idp, preferred_username: "Alice", email: "alice@example.com")
      conn = sso(conn, idp, "neiam")

      user = signed_in_user(conn)
      assert %{email: "alice@example.com", display_name: "Alice Example"} = user
      assert user.confirmed_at
      refute user.hashed_password
      assert [%Identity{preferred_username: "Alice"}] = Repo.all(Identity)
    end

    test "an existing account is matched by email, keeping its own display name",
         %{conn: conn, idp: idp} do
      user = user_fixture(email: "alice@example.com")
      {:ok, _} = Accounts.update_user_profile(user, %{display_name: "Al"})
      conn = sso(conn, idp, "neiam")
      assert signed_in_user(conn).id == user.id
      assert Accounts.get_user!(user.id).display_name == "Al"
    end
  end

  describe "PROVISION_GROUPS under invite_only" do
    setup do
      idp = idp()
      start_neiam(neiam_env(idp, provision: "invite_only", provision_groups: "admins"))
      %{idp: idp}
    end

    test "a member of admins gets an account; the same user without it is asked for an invite",
         %{conn: conn, idp: idp} do
      FakeIdP.put_user(idp, email: "new.person@example.com", groups: ["users"])

      conn = quietly(fn -> sso(conn, idp, "neiam") end)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Ask for an invite"
      refute signed_in_user(conn)
      assert Repo.all(Identity) == []

      FakeIdP.put_user(idp, email: "new.person@example.com", groups: ["users", "admins"])
      conn = sso(app_conn(), idp, "neiam")
      user = signed_in_user(conn)
      assert user.email == "new.person@example.com"

      assert [%Identity{sub: "fake-sub-1", groups: ["users", "admins"]} = identity] =
               Repo.all(Identity)

      assert identity.user_id == user.id
      # The admins group makes them an admin.
      assert FinalTrack.Accounts.get_user!(user.id).is_admin
    end
  end

  describe "two providers (neiam trusted, google not)" do
    setup do
      neiam = idp()
      google = idp(client_id: "final_track-at-google")

      google_env =
        FakeIdP.env(google, "google",
          redirect_uri: "http://localhost:4002/auth/oidc/google/callback",
          label: "Sign in with Google"
        )

      env =
        neiam
        |> FakeIdP.env("neiam",
          redirect_uri: "http://localhost:4002/auth/oidc/neiam/callback",
          groups_claim: "groups",
          trust_email: "true"
        )
        |> Map.merge(google_env)
        |> Map.put("OIDC_PROVIDERS", "neiam,google")

      start_neiam(env, ["neiam", "google"])
      %{neiam: neiam, google: google}
    end

    test "both buttons are shown", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ ~s(href="/auth/oidc/neiam/login")
      assert html =~ ~s(href="/auth/oidc/google/login")
    end

    test "an untrusted provider with the same email doesn't cross-link", %{
      conn: conn,
      google: google
    } do
      user_fixture(email: "alice@example.com")
      conn = quietly(fn -> sso(conn, google, "google") end)
      refute signed_in_user(conn)
      assert Repo.all(Identity) == []
    end

    test "state started at one provider is refused at the other's callback",
         %{conn: conn, neiam: neiam} do
      user_fixture(email: "alice@example.com")

      log =
        capture_log(fn -> send(self(), {:r, sso(conn, neiam, "neiam", callback: "google")}) end)

      assert_received {:r, conn}
      assert log =~ ":provider_mismatch"
      refute signed_in_user(conn)
    end

    test "the same sub at two issuers is two identities", %{
      conn: conn,
      neiam: neiam,
      google: google
    } do
      alice = user_fixture(email: "alice@example.com")
      conn = sso(conn, neiam, "neiam")
      assert signed_in_user(conn).id == alice.id

      conn = sso(conn |> recycle(), google, "google", query: %{"link" => "1"})
      assert redirected_to(conn) == ~p"/users/settings"
      assert Repo.all(Identity) |> Enum.map(& &1.issuer) |> Enum.uniq() |> length() == 2
    end
  end

  test "an unreachable issuer: boot is fine and the button answers with a flash", %{conn: conn} do
    capture_log(fn ->
      start_supervised!(
        {NeiamAuth,
         env: %{
           "OIDC_ENABLED" => "true",
           "OIDC_ISSUER" => "http://127.0.0.1:1",
           "OIDC_CLIENT_ID" => "final_track",
           "OIDC_CLIENT_SECRET" => "x",
           "OIDC_REDIRECT_URI" => "http://localhost:4002/auth/oidc/neiam/callback",
           "OIDC_ALLOW_UNSAFE_HTTP" => "true"
         },
         name: :neiam_auth_test,
         backoff_min: 50,
         backoff_max: 200}
      )

      conn = get(conn, "/auth/oidc/neiam/login")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "can't be reached"
    end)
  end
end

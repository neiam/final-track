defmodule FinalTrackWeb.LoginModeTest do
  @moduledoc """
  `OIDC_LOGIN_MODE` (neiam_auth v0.4.0): who may still use a password or a
  magic link, per mode; and in
  `sso_strict`, the hidden forms, refused registration and SSO invites.
  """
  use FinalTrackWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import FinalTrack.AccountsFixtures

  alias FinalTrack.Accounts
  alias NeiamAuth.Test.FakeIdP

  @refused "This account signs in with NEIAM"

  setup do
    on_exit(fn -> NeiamAuth.put_config(NeiamAuth.Config.load(%{})) end)
    idp = FakeIdP.start()
    on_exit(fn -> FakeIdP.stop(idp) end)
    %{idp: idp}
  end

  defp app_conn, do: Phoenix.ConnTest.build_conn()

  defp start_neiam(idp, extra) do
    env =
      idp
      |> FakeIdP.env(nil,
        redirect_uri: "http://localhost:4002/auth/oidc/neiam/callback",
        trust_email: "true",
        required_for_linked: "true",
        label: "Sign in with NEIAM"
      )
      |> Map.put("OIDC_ENABLED", "true")
      |> Map.merge(extra)

    start_supervised!(
      {NeiamAuth, env: env, name: :neiam_auth_test, backoff_min: 50, backoff_max: 200}
    )

    wait_ready()
  end

  defp wait_ready(tries \\ 100) do
    cond do
      not NeiamAuth.enabled?() ->
        :ok

      match?({:ok, _}, NeiamAuth.config("neiam")) and
          NeiamAuth.ready?(elem(NeiamAuth.config("neiam"), 1)) ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        wait_ready(tries - 1)

      true ->
        flunk("provider never loaded")
    end
  end

  # alice@example.com (FakeIdP's default user), with a password, linked by a
  # first SSO sign-in (TRUST_EMAIL). Returns the user and that SSO session.
  defp linked_user(idp) do
    user = set_password(user_fixture(email: "alice@example.com"))
    conn = get(app_conn(), "/auth/oidc/neiam/login")
    params = FakeIdP.authorize(idp, redirected_to(conn, 302))
    conn = conn |> recycle() |> get("/auth/oidc/neiam/callback", params)
    assert signed_in_user(conn).id == user.id
    assert [_] = NeiamAuth.identities(user)
    drain_emails()
    {user, conn}
  end

  defp unlinked_user do
    user = set_password(user_fixture())
    drain_emails()
    user
  end

  defp signed_in_user(conn) do
    case get_session(conn, :user_token) do
      nil -> nil
      token -> with {user, _} <- Accounts.get_user_by_session_token(token), do: user
    end
  end

  defp drain_emails do
    receive do
      {:email, _} -> drain_emails()
    after
      0 -> :ok
    end
  end

  defp password_log_in(conn \\ app_conn(), user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  defp magic_log_in(user) do
    token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
    {token, post(app_conn(), ~p"/users/log-in", %{"user" => %{"token" => token}})}
  end

  defp request_magic_link(user) do
    {:ok, lv, _html} = live(app_conn(), ~p"/users/log-in")

    {:ok, _lv, html} =
      lv
      |> form("#login_form_magic", user: %{email: user.email})
      |> render_submit()
      |> follow_redirect(app_conn(), ~p"/users/log-in")

    assert html =~ "If your email is in our system"
  end

  defp everything_works(user) do
    assert signed_in_user(password_log_in(user)).id == user.id

    {_token, conn} = magic_log_in(user)
    assert signed_in_user(conn).id == user.id

    request_magic_link(user)
    assert_email_sent(to: [{"", user.email}])
  end

  describe "sso" do
    setup %{idp: idp}, do: start_neiam(idp, %{"OIDC_LOGIN_MODE" => "sso"})

    test "a linked user's password log-in is refused", %{idp: idp} do
      {user, _conn} = linked_user(idp)
      assert NeiamAuth.login_mode() == :sso

      conn = password_log_in(user)
      refute signed_in_user(conn)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused

      # A wrong password still says only "Invalid email or password".
      conn =
        post(app_conn(), ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "not the password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
    end

    test "a linked user's magic link is refused, and not spent", %{idp: idp} do
      {user, _conn} = linked_user(idp)

      {token, conn} = magic_log_in(user)
      refute signed_in_user(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      assert Accounts.get_user_by_magic_link_token(token)
    end

    test "no magic link is mailed to a linked user, with the usual flash", %{idp: idp} do
      {user, _conn} = linked_user(idp)
      drain_emails()
      request_magic_link(user)
      assert_no_email_sent()
    end

    test "re-auth of the signed-in user is not a sign-in", %{idp: idp} do
      {user, conn} = linked_user(idp)
      conn = conn |> recycle() |> password_log_in(user)
      assert signed_in_user(conn).id == user.id
      refute Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "but signed in as someone else, it is a sign-in", %{idp: idp} do
      {user, _conn} = linked_user(idp)
      other = unlinked_user()
      conn = log_in_user(app_conn(), other)
      conn = password_log_in(conn, user)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
    end

    test "an unlinked user keeps every local way in" do
      user = unlinked_user()
      assert NeiamAuth.password_login_allowed?(user)
      everything_works(user)
    end
  end

  describe "mixed (the default)" do
    setup %{idp: idp}, do: start_neiam(idp, %{})

    test "a linked user keeps every local way in", %{idp: idp} do
      assert NeiamAuth.login_mode() == :mixed
      {user, _conn} = linked_user(idp)
      everything_works(user)
    end
  end

  describe "local" do
    setup %{idp: idp}, do: start_neiam(idp, %{"OIDC_LOGIN_MODE" => "local"})

    test "SSO is off and nothing is refused" do
      assert NeiamAuth.login_mode() == :local
      refute NeiamAuth.enabled?()
      assert get(app_conn(), "/auth/oidc/neiam/login").status == 404
      {:ok, _lv, html} = live(app_conn(), ~p"/users/log-in")
      refute html =~ "Sign in with NEIAM"

      everything_works(unlinked_user())
    end
  end

  describe "sso_strict" do
    setup %{idp: idp}, do: start_neiam(idp, %{"OIDC_LOGIN_MODE" => "sso_strict"})

    test "the log-in page shows the SSO button and no local form" do
      assert NeiamAuth.login_mode() == :sso_strict
      {:ok, _lv, html} = live(app_conn(), ~p"/users/log-in")
      assert html =~ ~s(href="/auth/oidc/neiam/login")
      refute html =~ "login_form_magic"
      refute html =~ "login_form_password"
      refute html =~ ~s(href="/users/register")
    end

    test "a password log-in is refused, linked or not", %{idp: idp} do
      {linked, _conn} = linked_user(idp)

      for user <- [linked, unlinked_user()] do
        conn = password_log_in(user)
        refute signed_in_user(conn)
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      end
    end

    test "magic links: none is mailed, an older one is refused" do
      user = unlinked_user()

      {token, conn} = magic_log_in(user)
      refute signed_in_user(conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ @refused
      assert Accounts.get_user_by_magic_link_token(token)
      drain_emails()

      # The form is gone; its event still mails nothing.
      {:ok, lv, _html} = live(app_conn(), ~p"/users/log-in")
      render_hook(lv, "submit_magic", %{"user" => %{"email" => user.email}})
      assert_no_email_sent()
    end

    test "registration redirects to log-in" do
      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(app_conn(), ~p"/users/register")

      assert flash["error"] =~ "signing in with NEIAM"
    end

    test "an invite is accepted by signing in with NEIAM", %{idp: idp} do
      {:ok, invite} = Accounts.create_invite(nil, %{email: "alice@example.com"})
      token = invite.token

      {:ok, _lv, html} = live(app_conn(), ~p"/users/register?invite=#{token}")
      assert html =~ "/users/register/invite/sso?"
      refute html =~ "password"

      # Not without the SSO login.
      conn =
        post(app_conn(), ~p"/users/register/invite", %{"invite" => token})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign in with NEIAM first"
      refute Accounts.get_user_by_email("alice@example.com")

      conn = get(app_conn(), ~p"/users/register/invite/sso", %{invite: token, provider: "neiam"})
      assert redirected_to(conn) == "/auth/oidc/neiam/login"
      conn = conn |> recycle() |> get("/auth/oidc/neiam/login")
      params = FakeIdP.authorize(idp, redirected_to(conn, 302))
      conn = conn |> recycle() |> get("/auth/oidc/neiam/callback", params)
      assert redirected_to(conn) == "/users/register?invite=#{URI.encode_www_form(token)}"

      {:ok, _lv, html} = conn |> recycle() |> live(~p"/users/register?invite=#{token}")
      assert html =~ "invite_sso_registration_form"
      refute html =~ "password"

      conn =
        conn
        |> recycle()
        |> post(~p"/users/register/invite", %{"invite" => token})

      user = signed_in_user(conn)
      assert user.email == "alice@example.com"
      refute user.hashed_password
      assert [_] = NeiamAuth.identities(user)
      refute Accounts.get_active_invite(token)
    end
  end

  describe "the kill switch" do
    test "OIDC_SSO_REQUIRED=false turns sso_strict into mixed", %{idp: idp} do
      start_neiam(idp, %{"OIDC_LOGIN_MODE" => "sso_strict", "OIDC_SSO_REQUIRED" => "false"})
      assert NeiamAuth.login_mode() == :mixed

      {:ok, _lv, html} = live(app_conn(), ~p"/users/log-in")
      assert html =~ "login_form_password"
      assert html =~ "login_form_magic"
      assert {:ok, _lv, _html} = live(app_conn(), ~p"/users/register")

      {user, _conn} = linked_user(idp)
      everything_works(user)
    end

    test "OIDC_SSO_REQUIRED=false turns sso into mixed", %{idp: idp} do
      start_neiam(idp, %{"OIDC_LOGIN_MODE" => "sso", "OIDC_SSO_REQUIRED" => "false"})
      assert NeiamAuth.login_mode() == :mixed

      {user, _conn} = linked_user(idp)
      everything_works(user)
    end
  end
end

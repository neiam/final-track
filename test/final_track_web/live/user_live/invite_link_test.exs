defmodule FinalTrackWeb.UserLive.InviteLinkTest do
  # Not async: flips the registration_open app env.
  use FinalTrackWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.Accounts
  alias FinalTrack.Accounts.Invite
  alias FinalTrack.Repo

  setup do
    Application.put_env(:final_track, :registration_open, false)
    on_exit(fn -> Application.put_env(:final_track, :registration_open, true) end)
  end

  defp join_params do
    %{
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    }
  end

  describe "an invite addressed to a new email" do
    test "registers that email confirmed and signs them in", %{conn: conn} do
      email = unique_user_email()
      {:ok, invite} = Accounts.create_invite(user_fixture(), %{email: email})

      {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")
      assert has_element?(lv, "#invite_registration_form")
      assert has_element?(lv, "#invite-email", email)
      refute has_element?(lv, "#registration_form")
      refute has_element?(lv, "#invite_registration_form input[name='user[email]']")

      form = form(lv, "#invite_registration_form", user: join_params())
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)

      user = Accounts.get_user_by_email(email)
      assert user.confirmed_at
      assert %{consumed_by_id: id} = Repo.get!(Invite, invite.id)
      assert id == user.id
    end

    test "the link works once", %{conn: conn} do
      {:ok, invite} = Accounts.create_invite(nil, %{email: unique_user_email()})
      params = %{"invite" => invite.token, "user" => join_params()}

      conn1 = post(conn, ~p"/users/register/invite", params)
      assert redirected_to(conn1) == ~p"/"

      conn2 = post(build_conn(), ~p"/users/register/invite", params)
      assert redirected_to(conn2) == ~p"/users/register"
      refute get_session(conn2, :user_token)
      assert Phoenix.Flash.get(conn2.assigns.flash, :error) =~ "isn't valid"

      {:ok, lv, _html} = live(build_conn(), ~p"/users/register?invite=#{invite.token}")
      assert has_element?(lv, "#registration-gated")
    end

    test "a bad password re-shows the form with errors", %{conn: conn} do
      {:ok, invite} = Accounts.create_invite(nil, %{email: unique_user_email()})
      {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")

      lv
      |> form("#invite_registration_form",
        user: %{password: "short", password_confirmation: "x"}
      )
      |> render_submit()

      assert has_element?(lv, "#invite_registration_form")
      assert Repo.get!(Invite, invite.id).consumed_at == nil
    end

    test "the regular save is refused, so another email can't use it", %{conn: conn} do
      {:ok, invite} = Accounts.create_invite(nil, %{email: unique_user_email()})
      {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")
      other = unique_user_email()

      render_hook(lv, "save", %{"user" => %{"email" => other}})

      refute Accounts.get_user_by_email(other)
      assert Repo.get!(Invite, invite.id).consumed_at == nil
    end
  end

  describe "an invite addressed to an email that has an account" do
    test "never signs anyone in; it sends them to log in", %{conn: conn} do
      existing = user_fixture()
      {:ok, invite} = Accounts.create_invite(nil, %{email: existing.email})

      {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")
      assert has_element?(lv, "#registration-has-account")
      assert has_element?(lv, "#invite-log-in[href='/users/log-in']")
      refute has_element?(lv, "#invite_registration_form")

      conn =
        post(conn, ~p"/users/register/invite", %{
          "invite" => invite.token,
          "user" => join_params()
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Repo.get!(Invite, invite.id).consumed_at == nil

      assert Accounts.get_user_by_email(existing.email).hashed_password ==
               existing.hashed_password
    end
  end

  test "an unaddressed invite can't be used to register confirmed", %{conn: conn} do
    {:ok, invite} = Accounts.create_invite(nil)

    conn =
      post(conn, ~p"/users/register/invite", %{
        "invite" => invite.token,
        "user" => Map.put(join_params(), :email, unique_user_email())
      })

    assert redirected_to(conn) == ~p"/users/register"
    refute get_session(conn, :user_token)
    assert Invite.active?(Repo.get!(Invite, invite.id))
  end

  describe "the invites page" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "makes a copyable link for an email", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/invites")
      email = unique_user_email()

      lv |> form("#invite-form", invite: %{email: email}) |> render_submit()

      assert [%Invite{email: ^email} = invite] = Accounts.list_invites(user)
      assert has_element?(lv, "#copy-shared-link[phx-hook]")
      url = lv |> element("#shared-link-url") |> render() |> url_from_input()
      assert Accounts.get_active_invite(invite_token_from_url(url)).id == invite.id
    end

    test "refuses a malformed email", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/invites")
      lv |> form("#invite-form", invite: %{email: "not an email"}) |> render_submit()

      assert Accounts.list_invites(user) == []
      assert has_element?(lv, "#invite-form .text-error")
    end

    test "\"New link\" stops the old link working", %{conn: conn, user: user} do
      {:ok, invite} = Accounts.create_invite(user, %{email: unique_user_email()})
      {:ok, lv, _html} = live(conn, ~p"/users/invites")

      lv |> element("#new-link-invites-#{invite.id}") |> render_click()

      refute Accounts.get_active_invite(invite.token)
      url = lv |> element("#shared-link-url") |> render() |> url_from_input()
      fresh_token = invite_token_from_url(url)
      assert fresh_token != invite.token
      assert Accounts.get_active_invite(fresh_token).id == invite.id

      {:ok, old_lv, _html} = live(build_conn(), ~p"/users/register?invite=#{invite.token}")
      assert has_element?(old_lv, "#registration-gated")
    end
  end

  defp url_from_input(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.attribute("value") |> hd()
  end
end

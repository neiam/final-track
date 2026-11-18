defmodule FinalTrackWeb.UserLive.RegistrationInviteTest do
  # Not async: flips the registration_open app env.
  use FinalTrackWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.Accounts

  setup do
    Application.put_env(:final_track, :registration_open, false)
    on_exit(fn -> Application.put_env(:final_track, :registration_open, true) end)
  end

  test "without an invite, the form is withheld", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")

    assert has_element?(lv, "#registration-gated")
    refute has_element?(lv, "#registration_form")
  end

  test "a bad invite token is the same as none", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register?invite=nope")
    assert has_element?(lv, "#registration-gated")
  end

  test "an invite lets one person register, and is then spent", %{conn: conn} do
    {:ok, invite} = Accounts.create_invite(nil)
    {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")
    assert has_element?(lv, "#registration-invited")

    attrs = valid_user_attributes()

    {:ok, _lv, _html} =
      lv
      |> form("#registration_form", user: attrs)
      |> render_submit()
      |> follow_redirect(conn, ~p"/users/log-in")

    user = Accounts.get_user_by_email(attrs.email)
    assert %{consumed_by_id: id} = FinalTrack.Repo.get!(FinalTrack.Accounts.Invite, invite.id)
    assert id == user.id

    {:ok, lv, _html} = live(build_conn(), ~p"/users/register?invite=#{invite.token}")
    assert has_element?(lv, "#registration-gated")
  end

  test "an invite spent in another tab is refused on submit", %{conn: conn} do
    {:ok, invite} = Accounts.create_invite(nil)
    {:ok, lv, _html} = live(conn, ~p"/users/register?invite=#{invite.token}")

    {:ok, _} = Accounts.consume_invite(invite, user_fixture())
    attrs = valid_user_attributes()
    lv |> form("#registration_form", user: attrs) |> render_submit()

    refute Accounts.get_user_by_email(attrs.email)
    assert has_element?(lv, "#registration-gated")
  end
end

defmodule FinalTrackWeb.UserLive.MailOffTest do
  # Flips :mail_enabled for the whole app: not async.
  use FinalTrackWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures
  import Swoosh.TestAssertions

  alias FinalTrack.Accounts

  setup do
    Application.put_env(:final_track, :mail_enabled, false)
    on_exit(fn -> Application.delete_env(:final_track, :mail_enabled) end)
  end

  test "log in: no emailed link, just the password", %{conn: conn} do
    # The fixture mails a confirmation as it sets the user up; not ours.
    user = user_fixture()
    assert_email_sent()

    {:ok, lv, _html} = live(conn, ~p"/users/log-in")
    refute has_element?(lv, "#login_form_magic")
    assert has_element?(lv, "#login_form_password")

    html = render_hook(lv, "submit_magic", %{"user" => %{"email" => user.email}})
    assert html =~ "doesn&#39;t send mail"
    assert_no_email_sent()
  end

  test "register with a password: confirmed, and signed straight in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    assert has_element?(lv, "#registration_form input[type=password]")

    email = unique_user_email()

    params = %{
      email: email,
      password: valid_user_password(),
      password_confirmation: valid_user_password()
    }

    form = form(lv, "#registration_form", user: params)
    render_submit(form)

    user = Accounts.get_user_by_email(email)
    assert user.confirmed_at
    assert_no_email_sent()

    conn = follow_trigger_action(form, conn)
    # A fresh sign-in lands on the live grid.
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created"
    assert get_session(conn, :user_token)
  end

  test "register: a short password is refused, nothing created", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/register")
    email = unique_user_email()

    html =
      lv
      |> form("#registration_form",
        user: %{email: email, password: "short", password_confirmation: "short"}
      )
      |> render_submit()

    assert html =~ "should be at least 12 character"
    refute Accounts.get_user_by_email(email)
  end

  test "settings: changing email is explained, not offered", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")
    assert has_element?(lv, "#email-change-unavailable")
    refute has_element?(lv, "#email_form")
  end
end

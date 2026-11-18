defmodule FinalTrackWeb.UserLive.InvitesTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "creates and revokes an invite", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/invites")
    assert has_element?(lv, "#invites-empty")

    lv |> form("#invite-form") |> render_submit()
    assert [invite] = Accounts.list_invites(user)
    assert has_element?(lv, "#invites-#{invite.id}")
    token = shown_token(lv)
    assert Accounts.get_active_invite(token).id == invite.id

    lv |> element("#revoke-invites-#{invite.id}") |> render_click()
    refute Accounts.get_active_invite(token)
    refute has_element?(lv, "#shared-link")
    refute has_element?(lv, "#revoke-invites-#{invite.id}")
  end

  test "shows a link once; the list has none", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/invites")
    refute has_element?(lv, "#shared-link")

    lv |> form("#invite-form", invite: %{email: unique_user_email()}) |> render_submit()
    [invite] = Accounts.list_invites(user)
    assert has_element?(lv, "#shared-link #copy-shared-link[phx-hook]")
    assert Accounts.get_active_invite(shown_token(lv)).id == invite.id

    lv |> element("#dismiss-shared-link") |> render_click()
    refute has_element?(lv, "#shared-link")

    # A fresh visit lists the invite, with no link anywhere on the page.
    {:ok, lv, html} = live(conn, ~p"/users/invites")
    assert has_element?(lv, "#invites-#{invite.id}")
    assert has_element?(lv, "#new-link-invites-#{invite.id}")
    refute has_element?(lv, "#shared-link")
    refute html =~ "invite="
  end

  defp shown_token(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#shared-link-url")
    |> LazyHTML.attribute("value")
    |> hd()
    |> invite_token_from_url()
  end
end

defmodule FinalTrackWeb.AdminLive.InstanceTest do
  use FinalTrackWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FinalTrack.AccountsFixtures

  alias FinalTrack.{Accounts, Instance}

  test "members who aren't admins are turned away, and see no link", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:error, {:redirect, %{to: "/charts"}}} = live(conn, ~p"/admin/instance")

    {:ok, lv, _html} = live(conn, ~p"/charts")
    refute has_element?(lv, "#nav-admin")
  end

  test "an admin sets the name and description", %{conn: conn} do
    {:ok, admin} = Accounts.set_admin(user_fixture(), true)
    conn = log_in_user(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/charts")
    assert has_element?(lv, "#nav-admin")

    {:ok, lv, _html} = live(conn, ~p"/admin/instance")

    lv
    |> form("#instance-form",
      instance: %{node_name: "The Den", node_description: "What we play."}
    )
    |> render_submit()

    assert Instance.node_name() == "The Den"

    assert %{"metadata" => %{"nodeName" => "The Den", "nodeDescription" => "What we play."}} =
             conn |> recycle() |> get(~p"/nodeinfo/2.1") |> json_response(200)
  end

  test "is_admin is never taken from a form" do
    user = user_fixture()

    {:ok, user} =
      Accounts.update_user_profile(user, %{"display_name" => "x", "is_admin" => "true"})

    refute user.is_admin
  end
end

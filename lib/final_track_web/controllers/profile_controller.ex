defmodule FinalTrackWeb.ProfileController do
  @moduledoc """
  `/@username`: a fediverse account's profile URL, Mastodon-style.

  One URL, two audiences. A server asking for ActivityPub JSON (someone
  pasted the URL into their search box) gets the actor document; a browser
  gets a public profile page with the account's recent plays — only the
  ones that aren't private, the same plays its followers see.

  Exists only while federation is on and the account is switched on.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.{Charts, Federation, Scrobbles}
  alias FinalTrack.Federation.Objects

  def show(conn, %{"username" => username}) do
    case Federation.get_live_account(username) do
      nil ->
        if activity_json?(conn) do
          send_resp(conn, 404, "")
        else
          # No :accepts in this pipeline, so the format is set here.
          conn
          |> put_format("html")
          |> put_status(:not_found)
          |> put_view(html: FinalTrackWeb.ErrorHTML)
          |> render(:"404")
        end

      account ->
        if activity_json?(conn) do
          conn
          |> put_resp_content_type("application/activity+json")
          |> send_resp(200, Jason.encode_to_iodata!(Objects.person(account)))
        else
          conn
          |> put_format("html")
          |> assign(:page_title, "@#{account.username}")
          |> render(:show,
            account: account,
            handle: "@#{account.username}@#{Objects.domain()}",
            name: FinalTrack.Accounts.User.display_name(account.user),
            followers: Federation.follower_count(account),
            plays: Scrobbles.recent(Charts.audience(nil, account.user), 24)
          )
        end
    end
  end

  defp activity_json?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&(&1 =~ "activity+json" or &1 =~ "ld+json"))
  end
end

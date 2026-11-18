defmodule FinalTrackWeb.FederationController do
  @moduledoc """
  ActivityPub's HTTP side: WebFinger and NodeInfo discovery, the instance
  and account actors, outboxes, follower counts, posted Notes and inboxes.
  All 404 while federation is off (`FinalTrackWeb.Plugs.RequireFederation`).

  Actor and Note URLs are also what a person may click in their fediverse
  client; a browser (anything not asking for ActivityPub JSON) is sent to
  the landing grid instead.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.Federation
  alias FinalTrack.Federation.{InstanceActor, Objects}
  alias FinalTrackWeb.Plugs.RawBodyReader

  ## Discovery

  def webfinger(conn, %{"resource" => resource}) do
    domain = Objects.domain()

    found =
      case resource do
        "acct:" <> acct ->
          case String.split(acct, "@", parts: 2) do
            [^domain, ^domain] -> Objects.instance_webfinger()
            [user, ^domain] -> account_jrd(Federation.get_live_account(user))
            _ -> nil
          end

        url ->
          case String.split(url, Objects.base() <> "/ap/users/", parts: 2) do
            ["", user] -> account_jrd(Federation.get_live_account(user))
            _ -> nil
          end
      end

    case found do
      nil ->
        send_resp(conn, 404, "")

      jrd ->
        conn
        |> put_resp_content_type("application/jrd+json")
        |> put_resp_header("access-control-allow-origin", "*")
        |> send_resp(200, Jason.encode_to_iodata!(jrd))
    end
  end

  def webfinger(conn, _params), do: send_resp(conn, 400, "")

  defp account_jrd(nil), do: nil
  defp account_jrd(account), do: Objects.webfinger(account)

  def nodeinfo_links(conn, _params), do: json(conn, Objects.nodeinfo_links())

  def nodeinfo(conn, _params) do
    conn
    |> put_resp_content_type(
      ~s(application/json; profile="http://nodeinfo.diaspora.software/ns/schema/2.0#")
    )
    |> send_resp(200, Jason.encode_to_iodata!(Objects.nodeinfo(Federation.usage())))
  end

  ## Actors and their collections

  def instance_actor(conn, _params),
    do: ap(conn, Objects.instance_actor(InstanceActor.ensure!()))

  def actor(conn, %{"username" => username}) do
    with_account(conn, username, &ap(conn, Objects.person(&1)))
  end

  def outbox(conn, %{"username" => username}) do
    with_account(conn, username, fn account ->
      ap(
        conn,
        Objects.outbox(account, Federation.post_count(account), Federation.latest_posts(account))
      )
    end)
  end

  def followers(conn, %{"username" => username}) do
    with_account(conn, username, &ap(conn, Objects.followers(&1, Federation.follower_count(&1))))
  end

  def note(conn, %{"id" => id}) do
    case Federation.get_post(id) do
      {:ok, post} -> ap(conn, Objects.note(post, post.account))
      # Was posted, mayn't be shown now (made private, account off).
      {:error, :gone} -> send_resp(conn, 410, "")
      {:error, :not_found} -> send_resp(conn, 404, "")
    end
  end

  defp with_account(conn, username, fun) do
    case Federation.get_live_account(username) do
      nil -> send_resp(conn, 404, "")
      account -> fun.(account)
    end
  end

  defp ap(conn, doc) do
    if wants_activity_json?(conn) do
      conn
      |> put_resp_content_type("application/activity+json")
      |> send_resp(200, Jason.encode_to_iodata!(doc))
    else
      redirect(conn, to: ~p"/")
    end
  end

  defp wants_activity_json?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&(&1 =~ "activity+json" or &1 =~ "ld+json" or &1 =~ "application/json"))
  end

  ## Inboxes

  def user_inbox(conn, %{"username" => username}) do
    case Federation.get_live_account(username) do
      nil -> send_resp(conn, 404, "")
      _account -> inbox(conn, %{})
    end
  end

  def inbox(conn, _params) do
    raw = RawBodyReader.raw_body(conn)

    request = %{
      method: :post,
      path: path_with_query(conn),
      # Plug carries the host on conn.host, not in req_headers; signatures
      # cover it as a header.
      headers: [{"host", host_header(conn)} | conn.req_headers],
      raw_body: raw
    }

    with {:ok, activity} <- decode(raw, conn.body_params),
         :ok <- Federation.receive_activity(request, activity) do
      send_resp(conn, 202, "")
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "")
      _ -> send_resp(conn, 400, "")
    end
  end

  defp decode(_raw, %{"type" => _} = params), do: {:ok, params}

  defp decode(raw, _params) do
    case Jason.decode(raw) do
      {:ok, %{} = activity} -> {:ok, activity}
      _ -> {:error, :bad_request}
    end
  end

  defp path_with_query(%{query_string: ""} = conn), do: conn.request_path
  defp path_with_query(conn), do: conn.request_path <> "?" <> conn.query_string

  defp host_header(%{host: host, port: port, scheme: scheme}) do
    if {scheme, port} in [{:https, 443}, {:http, 80}], do: host, else: "#{host}:#{port}"
  end
end

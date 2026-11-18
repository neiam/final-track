defmodule FinalTrackWeb.FederationController do
  @moduledoc """
  ActivityPub's HTTP side: WebFinger and NodeInfo discovery, the instance
  and account actors, outboxes, follower counts, posted Notes and inboxes.
  All 404 while federation is off (`FinalTrackWeb.Plugs.RequireFederation`).

  Actor and Note URLs are also what a person may click in their fediverse
  client; a browser (anything not asking for ActivityPub JSON) is sent to
  the account's `/@user` profile instead (`FinalTrackWeb.ProfileController`).
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.Federation
  alias FinalTrack.Federation.{InstanceActor, Objects}
  alias FinalTrackWeb.Plugs.RawBodyReader

  ## Discovery

  @doc """
  WebFinger (RFC 7033). The resource may be `acct:user@host` (with or
  without a leading `@` on the user, as people type handles), the account's
  actor URL or its `/@user` profile URL, or `acct:host@host` for the
  instance actor. Case-insensitive. Unknown or foreign resources are 404.
  """
  def webfinger(conn, %{"resource" => resource}) when is_binary(resource) do
    case resolve(String.trim(resource)) do
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

  defp resolve("acct:" <> acct) do
    domain = String.downcase(Objects.domain())

    case acct |> String.trim_leading("@") |> String.downcase() |> String.split("@", parts: 2) do
      [^domain, ^domain] -> Objects.instance_webfinger()
      [user, ^domain] -> account_jrd(Federation.get_live_account(user))
      _ -> nil
    end
  end

  defp resolve(url) do
    base = String.downcase(Objects.base())

    cond do
      String.downcase(url) == String.downcase(Objects.instance_actor_url()) ->
        Objects.instance_webfinger()

      String.starts_with?(String.downcase(url), base <> "/ap/users/") ->
        url |> String.slice(String.length(base <> "/ap/users/")..-1//1) |> account_by_path()

      String.starts_with?(String.downcase(url), base <> "/@") ->
        url |> String.slice(String.length(base <> "/@")..-1//1) |> account_by_path()

      true ->
        nil
    end
  end

  defp account_by_path(rest) do
    case String.split(rest, ["/", "?", "#"], parts: 2) do
      [user | _] when user != "" -> account_jrd(Federation.get_live_account(user))
      _ -> nil
    end
  end

  defp account_jrd(nil), do: nil
  defp account_jrd(account), do: Objects.webfinger(account)

  @doc """
  `/.well-known/host-meta` (RFC 6415): where WebFinger lives, for clients
  that look here first.
  """
  def host_meta(conn, _params) do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      <Link rel="lrdd" template="#{Objects.base()}/.well-known/webfinger?resource={uri}"/>
    </XRD>
    """

    conn
    |> put_resp_content_type("application/xrd+xml")
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(200, xml)
  end

  def nodeinfo_links(conn, _params), do: json(conn, Objects.nodeinfo_links())

  def nodeinfo(conn, %{"version" => version}) do
    if version in Objects.nodeinfo_versions() do
      conn
      |> put_resp_content_type(
        ~s(application/json; profile="http://nodeinfo.diaspora.software/ns/schema/#{version}#")
      )
      |> send_resp(200, Jason.encode_to_iodata!(Objects.nodeinfo(Federation.usage(), version)))
    else
      send_resp(conn, 404, "")
    end
  end

  ## Actors and their collections

  def instance_actor(conn, _params),
    do: ap(conn, Objects.instance_actor(InstanceActor.ensure!()))

  def actor(conn, %{"username" => username}) do
    with_account(conn, username, &ap(conn, Objects.person(&1), Objects.profile_url(&1)))
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
      {:ok, post} -> ap(conn, Objects.note(post, post.account), Objects.profile_url(post.account))
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

  # A browser gets `html_to` (the account's profile, or the landing grid).
  defp ap(conn, doc, html_to \\ nil) do
    cond do
      wants_activity_json?(conn) ->
        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode_to_iodata!(doc))

      html_to ->
        redirect(conn, external: html_to)

      true ->
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

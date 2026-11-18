defmodule FinalTrack.Federation.HTTP do
  @moduledoc """
  Guarded server-to-server HTTP for federation: the only place final_track
  talks to other fediverse servers. Ported from angler's
  `Angler.Federation.HTTP` (minus its ban list, host back-off and bearer
  tokens).

    * Scheme must be `https` (`http` only with `allow_http: true`, for dev).
    * The resolved host must not be in a private, loopback, link-local,
      CGNAT, multicast or reserved range, so a remote server can't point us
      at our own network. Redirects are followed by hand so every hop is
      re-checked; POSTs never follow them.
    * The connection goes to the address that was checked
      (`FinalTrack.Federation.HTTP.PinnedAdapter`), so DNS rebinding can't
      slip a second, private answer past the check.
    * Fetched documents must be an ActivityPub/JSON content type, and at
      most 1 MiB.

  Config, `config :final_track, FinalTrack.Federation.HTTP`:
    * `allow_http` (default false)
    * `guard_addresses` (default true; tests turn it off and stub with Req.Test)
    * `req_options`, merged into every request (`plug: {Req.Test, ...}` in tests)
  """

  alias FinalTrack.Federation.HTTP.PinnedAdapter
  alias FinalTrack.Federation.HTTPSignature

  @ap_content_types ~w(application/activity+json application/ld+json application/jrd+json application/json)
  @accept ~s(application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams")
  @max_body_bytes 1_048_576
  @max_redirects 3

  defp config, do: Application.get_env(:final_track, __MODULE__, [])

  @doc """
  GETs an ActivityPub document. `signed_with: {key_id, private_key_pem}`
  signs the request (servers in authorized-fetch mode refuse unsigned ones).
  `{:ok, map}` or `{:error, reason}`.
  """
  def fetch(url, opts \\ []) when is_binary(url) do
    with {:ok, resp} <- get_following_redirects(url, opts[:signed_with], @max_redirects),
         :ok <- check_status(resp.status),
         :ok <- check_size(resp.body),
         :ok <- check_content_type(resp.headers),
         {:ok, %{} = doc} <- Jason.decode(resp.body) do
      {:ok, doc}
    else
      {:ok, _not_a_map} -> {:error, :bad_json}
      {:error, %Jason.DecodeError{}} -> {:error, :bad_json}
      other -> other
    end
  end

  @doc """
  POSTs `activity` (a map) to an inbox, signed with `{key_id, private_key_pem}`.
  `{:ok, status}` for a 2xx, or `{:error, reason}` (`{:unavailable, status}` for 408/429/5xx,
  which are worth retrying).
  """
  def deliver(inbox, activity, {key_id, private_key_pem}) do
    body = Jason.encode!(activity)

    with {:ok, uri, ip} <- check_url(inbox) do
      {:ok, headers} =
        HTTPSignature.sign(
          :post,
          request_target(uri),
          host_header(uri),
          body,
          key_id,
          private_key_pem,
          [
            {"Content-Type", "application/activity+json"}
          ]
        )

      [
        method: :post,
        url: inbox,
        body: body,
        headers: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end),
        redirect: false,
        retry: false,
        receive_timeout: 15_000,
        connect_options: [timeout: 5_000]
      ]
      |> request(uri, ip)
      |> case do
        {:ok, %{status: s}} when s in 200..299 -> {:ok, s}
        {:ok, %{status: s}} -> check_status(s)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Whether a delivery error is worth retrying later."
  def transient_error?({:unavailable, _status}), do: true
  def transient_error?(:unresolvable), do: true
  def transient_error?(%Req.TransportError{}), do: true
  def transient_error?(_), do: false

  ## Internals

  defp get_following_redirects(url, signed_with, hops_left) do
    with {:ok, uri, ip} <- check_url(url),
         {:ok, resp} <-
           request(
             [
               method: :get,
               url: url,
               headers: get_headers(uri, signed_with),
               redirect: false,
               retry: false,
               receive_timeout: 10_000,
               connect_options: [timeout: 5_000],
               decode_body: false
             ],
             uri,
             ip
           ) do
      case {resp.status, Req.Response.get_header(resp, "location")} do
        {status, [location | _]} when status in [301, 302, 303, 307, 308] ->
          if hops_left > 0 do
            next = uri |> URI.merge(location) |> URI.to_string()
            get_following_redirects(next, signed_with, hops_left - 1)
          else
            {:error, :too_many_redirects}
          end

        _ ->
          {:ok, resp}
      end
    end
  end

  defp get_headers(_uri, nil), do: [{"accept", @accept}]

  defp get_headers(uri, {key_id, private_key_pem}) do
    {:ok, headers} =
      HTTPSignature.sign(
        :get,
        request_target(uri),
        host_header(uri),
        "",
        key_id,
        private_key_pem,
        [
          {"Accept", @accept}
        ]
      )

    Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
  end

  # `ip` is nil when the address guard is off; the request then goes through
  # Req's default adapter (where tests plug in Req.Test).
  defp request(req_opts, _uri, nil) do
    req_opts |> Keyword.merge(overrides()) |> Req.request()
  end

  defp request(req_opts, uri, ip) do
    req_opts
    |> Keyword.put(:adapter, PinnedAdapter)
    |> Keyword.merge(overrides())
    |> Req.new()
    |> Req.Request.put_private(:final_track_pin, {ip, uri.host})
    |> Req.Request.put_private(:final_track_max_body_bytes, @max_body_bytes)
    |> Req.request()
  end

  # Not `headers:`: Keyword.merge would replace the request's own headers
  # (the signature with them).
  defp overrides do
    [user_agent: "FinalTrack/0.1 (+#{FinalTrackWeb.base_url()})"]
    |> Keyword.merge(Keyword.get(config(), :req_options, []))
  end

  @doc false
  # Public for tests: `{:ok, uri, ip_or_nil}` or `{:error, reason}`.
  def check_url(url) do
    with {:ok, %URI{scheme: scheme, host: host} = uri} <- parse_uri(url),
         :ok <- check_scheme(scheme),
         {:ok, ip} <- check_resolved_host(host) do
      {:ok, uri, ip}
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h} = uri when is_binary(s) and is_binary(h) and h != "" -> {:ok, uri}
      _ -> {:error, :bad_url}
    end
  end

  defp check_scheme("https"), do: :ok

  defp check_scheme("http"),
    do: if(Keyword.get(config(), :allow_http, false), do: :ok, else: {:error, :bad_scheme})

  defp check_scheme(_), do: {:error, :bad_scheme}

  defp check_resolved_host(host) do
    cond do
      not Keyword.get(config(), :guard_addresses, true) -> {:ok, nil}
      resolver = config()[:resolver] -> resolve_and_check(host, resolver)
      true -> resolve_and_check(host, &:inet.getaddrs/2)
    end
  end

  # IP literals skip DNS. Every resolved address must be public; the first
  # one is what we connect to.
  defp resolve_and_check(host, resolver) do
    host = String.to_charlist(host)

    addrs =
      case :inet.parse_address(host) do
        {:ok, addr} ->
          [addr]

        _ ->
          with {:error, _} <- resolver.(host, :inet),
               {:error, _} <- resolver.(host, :inet6) do
            []
          else
            {:ok, addrs} -> addrs
          end
      end

    cond do
      addrs == [] -> {:error, :unresolvable}
      Enum.any?(addrs, &private_ip?/1) -> {:error, :private_address}
      true -> {:ok, hd(addrs)}
    end
  end

  @private_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @private_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc false
  def private_ip?({_, _, _, _} = ip), do: Enum.any?(@private_v4, &in_cidr?(ip, &1, 8))
  # ::ffff:a.b.c.d (IPv4-mapped) and 64:ff9b::a.b.c.d (NAT64)
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: private_ip?(embedded_v4(hi, lo))
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: private_ip?(embedded_v4(hi, lo))

  def private_ip?({_, _, _, _, _, _, _, _} = ip),
    do: Enum.any?(@private_v6, &in_cidr?(ip, &1, 16))

  def private_ip?(_), do: false

  defp embedded_v4(hi, lo), do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  defp in_cidr?(ip, {net, prefix}, bits_per_part) do
    shift = tuple_size(ip) * bits_per_part - prefix

    Bitwise.bsr(to_int(ip, bits_per_part), shift) ==
      Bitwise.bsr(to_int(net, bits_per_part), shift)
  end

  defp to_int(tuple, bits),
    do:
      tuple
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc -> Bitwise.bsl(acc, bits) + part end)

  defp check_status(s) when s in 200..299, do: :ok
  defp check_status(s) when s in [408, 429] or s in 500..599, do: {:error, {:unavailable, s}}
  defp check_status(s), do: {:error, {:bad_status, s}}

  defp check_size(body) when byte_size(body) <= @max_body_bytes, do: :ok
  defp check_size(_), do: {:error, :too_large}

  defp check_content_type(headers) do
    ct =
      headers
      |> Enum.find_value(fn {k, v} ->
        if String.downcase(to_string(k)) == "content-type", do: v
      end)
      |> List.wrap()
      |> List.first()
      |> to_string()
      |> String.downcase()
      |> String.split(";")
      |> List.first()
      |> String.trim()

    if ct in @ap_content_types, do: :ok, else: {:error, :bad_content_type}
  end

  # `(request-target)` covers the query string too: signing the bare path
  # fails on authorized-fetch servers.
  defp request_target(%URI{path: path, query: nil}), do: path || "/"
  defp request_target(%URI{path: path, query: q}), do: (path || "/") <> "?" <> q

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if {scheme, port} in [{"https", 443}, {"http", 80}] or is_nil(port),
      do: host,
      else: "#{host}:#{port}"
  end
end

import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/final_track start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :final_track, FinalTrackWeb.Endpoint, server: true
end

config :final_track, FinalTrackWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :final_track, FinalTrackWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/final_track_web/router\.ex$"E,
        ~r"lib/final_track_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # What the server calls itself (NodeInfo, its fediverse actor): defaults an
  # admin's Instance page overrides.
  config :final_track, FinalTrack.Instance,
    node_name: System.get_env("FINAL_TRACK_NODE_NAME"),
    node_description: System.get_env("FINAL_TRACK_NODE_DESCRIPTION")

  # Members of this OIDC group become admins when they sign in.
  config :final_track, :admin_group, System.get_env("FINAL_TRACK_ADMIN_GROUP", "admins")

  # ActivityPub: off unless FINAL_TRACK_ACTIVITYPUB=true. PHX_HOST must be
  # the public domain first: it's the domain fediverse accounts live on.
  config :final_track, FinalTrack.Federation,
    enabled: System.get_env("FINAL_TRACK_ACTIVITYPUB", "false") == "true"

  # Where album covers are stored, and how the server introduces itself to
  # MusicBrainz (put a contact URL or address in it).
  config :final_track, FinalTrack.Covers,
    root: System.get_env("FINAL_TRACK_COVERS_DIR", "/var/lib/final_track/covers"),
    auto_fetch: System.get_env("FINAL_TRACK_AUTO_FETCH_COVERS", "true") == "true",
    # Between MusicBrainz requests, per pod. MusicBrainz allows ~1/s per IP
    # and every replica runs its own queue: 2.2s keeps two pods under it.
    interval_ms: String.to_integer(System.get_env("FINAL_TRACK_COVER_INTERVAL_MS", "2200")),
    user_agent:
      System.get_env(
        "FINAL_TRACK_MUSICBRAINZ_USER_AGENT",
        "FinalTrack/0.1 (self-hosted scrobble server)"
      )

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  # As diogramos: discrete POSTGRES_* vars first (StackGres passwords carry
  # URL-significant characters that DATABASE_URL would mangle), DATABASE_URL
  # otherwise.
  cond do
    System.get_env("POSTGRES_HOST") ->
      config :final_track, FinalTrack.Repo,
        hostname: System.get_env("POSTGRES_HOST"),
        port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
        username:
          System.get_env("POSTGRES_USER") ||
            raise("POSTGRES_USER is required when POSTGRES_HOST is set"),
        password:
          System.get_env("POSTGRES_PASSWORD") ||
            raise("POSTGRES_PASSWORD is required when POSTGRES_HOST is set"),
        database: System.get_env("POSTGRES_DB") || "final_track",
        pool_size: pool_size,
        socket_options: maybe_ipv6

    System.get_env("DATABASE_URL") ->
      config :final_track, FinalTrack.Repo,
        url: System.get_env("DATABASE_URL"),
        pool_size: pool_size,
        socket_options: maybe_ipv6

    true ->
      raise """
      Database configuration missing. Set either:
        - POSTGRES_HOST + POSTGRES_USER + POSTGRES_PASSWORD (preferred), or
        - DATABASE_URL (e.g. ecto://USER:PASS@HOST/DATABASE)
      """
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :final_track, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Clustering, as diogramos: libcluster lists this namespace's pods
  # labelled name=finaltrack (RBAC in argo-01-bos/finaltrack/app.yml) and
  # connects to final_track@<pod ip> (rel/env.sh.eex). Off unless
  # CLUSTER_NAMESPACE is set, so a release run anywhere else stays alone.
  if namespace = System.get_env("CLUSTER_NAMESPACE") do
    config :libcluster,
      topologies: [
        final_track: [
          strategy: Cluster.Strategy.Kubernetes,
          config: [
            mode: :ip,
            # Peers are found by listing pods with the selector (the default,
            # :endpoints, filters by the Service's labels and finds nobody).
            kubernetes_ip_lookup_mode: :pods,
            kubernetes_selector: "name=finaltrack",
            kubernetes_service_name: "finaltrack-headless",
            kubernetes_node_basename: "final_track",
            kubernetes_namespace: namespace,
            polling_interval: 10_000
          ]
        ]
      ]
  end

  # Mail is optional. As diogramos: SMTP when SMTP_RELAY is set (and, if the
  # relay requires auth, SMTP_PASSWORD too), else off: the Logger adapter
  # (mail in the pod log; also gets us off Swoosh.Adapters.Local, which is
  # what the log-in page checks for to show the dev-mailbox banner), and
  # FinalTrack.Mailer.enabled?/0 false, so nothing waits on a mail that won't
  # come.
  # Spelled out, not String.to_existing_atom/1: runtime.exs runs before
  # gen_smtp is loaded, so :if_available may not exist yet (diogramos only
  # escapes this because its deployment sets the values to never/always).
  smtp_tri = fn var, default ->
    case System.get_env(var, default) do
      "always" -> :always
      "if_available" -> :if_available
      "never" -> :never
      other -> raise "#{var} must be one of always|if_available|never, got: #{inspect(other)}"
    end
  end

  relay = System.get_env("SMTP_RELAY")

  mail_enabled? =
    relay not in [nil, ""] and
      (System.get_env("SMTP_PASSWORD") not in [nil, ""] or
         System.get_env("SMTP_AUTH", "if_available") != "always")

  config :final_track, :mail_enabled, mail_enabled?

  mailer_opts =
    if mail_enabled? do
      [
        adapter: Swoosh.Adapters.SMTP,
        relay: relay,
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        tls: smtp_tri.("SMTP_TLS", "if_available"),
        ssl: System.get_env("SMTP_SSL", "false") == "true",
        auth: smtp_tri.("SMTP_AUTH", "if_available"),
        tls_options: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(relay),
          depth: 99
        ],
        retries: 1,
        no_mx_lookups: false
      ]
    else
      [adapter: Swoosh.Adapters.Logger, level: :info]
    end

  config :final_track,
         FinalTrack.Mailer,
         mailer_opts ++
           [
             from_name: System.get_env("MAIL_FROM_NAME", "Final Track"),
             from_address: System.get_env("MAIL_FROM_ADDRESS") || "noreply@#{host}"
           ]

  config :final_track, FinalTrackWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Both forms, so the LiveView socket isn't refused when the proxy
    # forwards a subtly different Origin (as diogramos found).
    check_origin: ["//#{host}", "https://#{host}"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :final_track, FinalTrackWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :final_track, FinalTrackWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :final_track, FinalTrack.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :final_track, :scopes,
  user: [
    default: true,
    module: FinalTrack.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: FinalTrack.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :final_track,
  ecto_repos: [FinalTrack.Repo],
  # Invite-only unless set true. Invites: `mix final_track.invite` or the
  # /users/invites page.
  registration_open: false,
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Album covers (FinalTrack.Covers). Files live under :root (default
# priv/uploads); auto_fetch looks up a cover on MusicBrainz / the Cover Art
# Archive the first time an album without one is played. MusicBrainz asks
# for a User-Agent naming the app and a way to reach its operator.
config :final_track, FinalTrack.Covers,
  auto_fetch: true,
  user_agent: "FinalTrack/0.1 (self-hosted scrobble server)"

# ActivityPub (FinalTrack.Federation): off unless enabled. With it on,
# members can give their plays a fediverse account in Scrobbling settings.
# The endpoint's url (host) is the domain accounts live on: set it right
# before enabling, since remote servers remember actor URLs.
config :final_track, FinalTrack.Federation, enabled: false

# "Sign in with NEIAM" (neiam_auth). Everything else is OIDC_* env, read at
# start; with OIDC_ENABLED unset (the default) the library does nothing.
config :neiam_auth,
  repo: FinalTrack.Repo,
  user_schema: FinalTrack.Accounts.User,
  adapter: FinalTrack.NeiamAuthAdapter

# Configure the endpoint
config :final_track, FinalTrackWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FinalTrackWeb.ErrorHTML, json: FinalTrackWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FinalTrack.PubSub,
  live_view: [signing_salt: "+us4vJq2"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :final_track, FinalTrack.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  final_track: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  final_track: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

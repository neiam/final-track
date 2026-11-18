import Config

# Tests assume open registration unless they opt out.
config :final_track, :registration_open, true

# Covers: no automatic lookups, no pacing, HTTP stubbed through Req.Test,
# files in a throwaway directory.
config :final_track, FinalTrack.Covers,
  auto_fetch: false,
  interval_ms: 0,
  root: Path.join(System.tmp_dir!(), "final_track_test_covers"),
  req_options: [plug: {Req.Test, FinalTrack.Covers.Fetcher}, retry: false]

# ActivityPub on, deliveries in the caller with no wait or retries, remote
# servers stubbed through Req.Test (so no address guard: there's no DNS).
config :final_track, FinalTrack.Federation,
  enabled: true,
  delivery: :inline,
  post_delay_ms: 0,
  cover_waits: 0

config :final_track, FinalTrack.Federation.HTTP,
  guard_addresses: false,
  req_options: [plug: {Req.Test, FinalTrack.Federation.HTTP}]

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :final_track, FinalTrack.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "final_track_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # LiveView processes share a test's sandbox connection; under a full
  # parallel suite the default 50ms queue target made them give up.
  queue_target: 1_000,
  queue_interval: 5_000,
  pool_size: System.schedulers_online() * 2,
  # compose.yml's postgres by default; POSTGRES_PORT=5432 for the host's own.
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "54330")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :final_track, FinalTrackWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gKM+jxs2tXs4GsBVqaA0P7zw+9l+w9GUumDpVu05JTMMc8uAG4fUNBoHR5ZixpFK",
  server: false

# In test we don't send emails
config :final_track, FinalTrack.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

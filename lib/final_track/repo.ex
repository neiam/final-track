defmodule FinalTrack.Repo do
  use Ecto.Repo,
    otp_app: :final_track,
    adapter: Ecto.Adapters.Postgres
end

defmodule FinalTrack.Mailer do
  use Swoosh.Mailer, otp_app: :final_track

  @doc """
  Whether this server sends mail. Off (`config :final_track, :mail_enabled,
  false`, set by runtime.exs when no relay is configured) means mail is only
  logged: the log-in page drops its emailed-link form, registration takes a
  password instead of confirming by email, and changing email is
  unavailable. Invites addressed to an email and Sign in with NEIAM never
  needed mail.
  """
  def enabled?, do: Application.get_env(:final_track, :mail_enabled, true) == true

  @doc """
  Who mail comes from: the mailer's `:from_name` / `:from_address` config,
  "Final Track" at `noreply@localhost` otherwise.
  """
  def from do
    config = Application.get_env(:final_track, __MODULE__, [])

    {Keyword.get(config, :from_name, "Final Track"),
     Keyword.get(config, :from_address, "noreply@localhost")}
  end
end

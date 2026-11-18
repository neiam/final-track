defmodule Mix.Tasks.FinalTrack.Admin do
  @shortdoc "Make an account an admin, or revoke it"
  @moduledoc """
  Admins edit instance settings (the node name and description).

      mix final_track.admin you@example.com
      mix final_track.admin --revoke you@example.com

  Members of the OIDC admin group become admins on sign-in anyway. In a
  release, the same thing is `bin/admin`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [revoke: :boolean])

    with [email] <- rest,
         %{} = user <- FinalTrack.Accounts.get_user_by_email(email),
         {:ok, user} <- FinalTrack.Accounts.set_admin(user, !opts[:revoke]) do
      Mix.shell().info(
        "#{user.email} is #{if user.is_admin, do: "now an admin", else: "no longer an admin"}"
      )
    else
      nil -> Mix.raise("No user with that email")
      _ -> Mix.raise("usage: mix final_track.admin [--revoke] EMAIL")
    end
  end
end

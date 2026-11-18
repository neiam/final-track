defmodule Mix.Tasks.FinalTrack.Invite.Link do
  @shortdoc "Print a fresh link for an invite addressed to an email"
  @moduledoc """
  Print a fresh link for the newest active invite addressed to an email,
  for when the first link was lost or went to the wrong place. The invite's
  token is replaced, so any earlier link to it stops working.

      mix final_track.invite.link sam@example.com

  Make an addressed invite with `mix final_track.invite --email`.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    case args do
      [email] ->
        case FinalTrack.Accounts.rotate_invite_for_email(email) do
          {:ok, invite} ->
            Mix.shell().info(FinalTrackWeb.invite_url(invite))

            Mix.shell().info(
              FinalTrack.Accounts.Invite.describe(invite) <>
                " Any earlier link to it no longer works."
            )

          {:error, _} ->
            Mix.shell().error("No active invite for #{email}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error("usage: mix final_track.invite.link EMAIL")
        exit({:shutdown, 1})
    end
  end
end

defmodule Mix.Tasks.FinalTrack.Invite do
  @shortdoc "Create a registration invite link"
  @moduledoc """
  Create a single-use registration invite and print its link. Nothing is
  emailed: hand the link over yourself.

      mix final_track.invite
      mix final_track.invite --email sam@example.com
      mix final_track.invite --note "for Sam" --days 7
      mix final_track.invite --by you@example.com

    * `--email` whom it is for: the link then registers that address only,
                asking just a password, counting the email as
                confirmed and signing them in (if it already has an
                account, the link sends them to log in)
    * `--note`  a reminder of who it is for, shown on the invites page
    * `--days`  expire after this many days (default: never)
    * `--by`    the user it belongs to, so it shows up on their invites page

  With no `--by`, the invite belongs to nobody. It still works; it just
  appears in no one's list, which is what the very first invite has to look
  like when there is nobody to own it yet.

  For a fresh link to an addressed invite, see `mix final_track.invite.link`.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [email: :string, note: :string, days: :integer, by: :string]
      )

    case FinalTrack.Accounts.create_invite_from_cli(opts) do
      {:ok, invite} ->
        Mix.shell().info(FinalTrackWeb.invite_url(invite))
        Mix.shell().info(FinalTrack.Accounts.Invite.describe(invite))

      {:error, :no_such_user} ->
        Mix.shell().error("No user with email #{opts[:by]}")
        exit({:shutdown, 1})

      {:error, changeset} ->
        Mix.shell().error("Could not create invite: #{inspect(changeset.errors)}")
        exit({:shutdown, 1})
    end
  end
end

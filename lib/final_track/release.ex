defmodule FinalTrack.Release do
  @moduledoc """
  Operational tasks for a release, where there's no Mix (as clayman's):

      bin/migrate                     # FinalTrack.Release.migrate/0
      bin/invite [--email sam@example.com] [--note "for Sam"] [--days 7] [--by you@example.com]
      bin/invite-link sam@example.com
      bin/final_track eval 'FinalTrack.Release.rollback(FinalTrack.Repo, 20261118195445)'

  In dev, the same invites are `mix final_track.invite` and
  `mix final_track.invite.link`.
  """
  @app :final_track

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates a registration invite and prints its link, for a release with no
  Mix: `bin/invite [--email sam@example.com] [--note "for Sam"] [--days 7]
  [--by you@example.com]`.

  Nothing is emailed: hand the link over yourself. With `--email` the link
  is for that address only, and lets them register from it alone (a
  password, email counted as confirmed, signed in). Without one, whoever
  holds it can register once.

  The shell script turns its flags into `INVITE_EMAIL`, `INVITE_NOTE`,
  `INVITE_DAYS` and `INVITE_BY`, so nothing typed on the command line is
  ever spliced into the Elixir that `eval` runs. The link goes to stdout,
  what it does to stderr.
  """
  def invite do
    load_app()

    opts =
      [
        email: env("INVITE_EMAIL"),
        note: env("INVITE_NOTE"),
        by: env("INVITE_BY"),
        days: with(d when is_binary(d) <- env("INVITE_DAYS"), do: String.to_integer(d))
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(FinalTrack.Repo, fn _repo ->
        FinalTrack.Accounts.create_invite_from_cli(opts)
      end)

    case result do
      {:ok, invite} ->
        IO.puts(:stderr, FinalTrack.Accounts.Invite.describe(invite))
        IO.puts(FinalTrackWeb.invite_url(invite))

      {:error, :no_such_user} ->
        IO.puts(:stderr, "No user with email #{opts[:by]}")
        System.halt(1)

      {:error, changeset} ->
        IO.puts(:stderr, "Could not create invite: #{inspect(changeset.errors)}")
        System.halt(1)
    end
  end

  @doc """
  Prints a fresh link for the newest active invite addressed to an email,
  for a release with no Mix: `bin/invite-link sam@example.com` (which sets
  `INVITE_EMAIL`). Earlier links to that invite stop working.
  """
  def invite_link do
    load_app()
    email = env("INVITE_EMAIL") || raise "INVITE_EMAIL is required"

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(FinalTrack.Repo, fn _repo ->
        FinalTrack.Accounts.rotate_invite_for_email(email)
      end)

    case result do
      {:ok, invite} ->
        IO.puts(
          :stderr,
          FinalTrack.Accounts.Invite.describe(invite) <>
            " Any earlier link to it no longer works."
        )

        IO.puts(FinalTrackWeb.invite_url(invite))

      {:error, _} ->
        IO.puts(:stderr, "No active invite for #{email}")
        System.halt(1)
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end

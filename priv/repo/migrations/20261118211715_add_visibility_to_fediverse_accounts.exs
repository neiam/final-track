defmodule FinalTrack.Repo.Migrations.AddVisibilityToFediverseAccounts do
  use Ecto.Migration

  # Who an account's posts are addressed to: "unlisted" (followers' feeds,
  # off public timelines and, on Pixelfed/angler, off the profile page) or
  # "public" (also the profile page and public timelines).
  def change do
    alter table(:fediverse_accounts) do
      add :visibility, :string, null: false, default: "unlisted"
    end
  end
end

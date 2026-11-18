defmodule FinalTrack.Repo.Migrations.AddHashtagToFediverseAccounts do
  use Ecto.Migration

  # A hashtag added to every post, without the "#". On by default
  # (existing accounts included); NULL means none.
  def change do
    alter table(:fediverse_accounts) do
      add :hashtag, :string, default: "scropple"
    end
  end
end

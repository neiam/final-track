defmodule FinalTrack.Repo.Migrations.AddTagArtistToFediverseAccounts do
  use Ecto.Migration

  # Whether posts also carry the artist as a hashtag (Pink Floyd ->
  # #pinkfloyd). Opt-in: it puts plays into the artist's public tag stream.
  def change do
    alter table(:fediverse_accounts) do
      add :tag_artist, :boolean, null: false, default: false
    end
  end
end

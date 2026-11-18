defmodule FinalTrack.Repo.Migrations.CreatePrivateMarks do
  use Ecto.Migration

  # A user's "keep this to myself": their plays of a marked artist, album or
  # track are left out of everything other people see. Exactly one of the
  # three targets is set per row.
  def change do
    create table(:private_marks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :artist_id, references(:artists, type: :uuid, on_delete: :delete_all)
      add :album_id, references(:albums, type: :uuid, on_delete: :delete_all)
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:private_marks, :exactly_one_target,
             check: "num_nonnulls(artist_id, album_id, track_id) = 1"
           )

    create unique_index(:private_marks, [:user_id, :artist_id], where: "artist_id IS NOT NULL")
    create unique_index(:private_marks, [:user_id, :album_id], where: "album_id IS NOT NULL")
    create unique_index(:private_marks, [:user_id, :track_id], where: "track_id IS NOT NULL")
  end
end

defmodule FinalTrack.Repo.Migrations.CreateScrobbling do
  use Ecto.Migration

  # The catalog (artists, albums, tracks) is shared by everyone and keyed on
  # a normalised name (`FinalTrack.Catalog.normalize/1`), so "The Beatles"
  # and "the  beatles" are one artist and a cover attaches to an album once.
  # Scrobbles are per user.
  def change do
    create table(:artists, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:artists, [:key])

    create table(:albums, primary_key: false) do
      add :id, :uuid, primary_key: true
      # The album artist when the client sent one, else the track artist.
      add :artist_id, references(:artists, type: :uuid, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :key, :string, null: false
      # Relative key under the cover store's root; nil = no cover.
      add :cover_key, :string
      # "upload" | "coverartarchive"
      add :cover_source, :string
      # MusicBrainz release-group id, once looked up.
      add :mbid, :string
      # Last automatic lookup, so a miss isn't retried on every scrobble.
      add :cover_checked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:albums, [:artist_id, :key])

    create table(:tracks, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :artist_id, references(:artists, type: :uuid, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :key, :string, null: false
      add :duration_sec, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tracks, [:artist_id, :key])

    create table(:scrobbles, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      # Denormalised from the track / the client's album, so charts group
      # without joins.
      add :artist_id, references(:artists, type: :uuid, on_delete: :delete_all), null: false
      add :album_id, references(:albums, type: :uuid, on_delete: :nilify_all)
      add :played_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Clients retry whole batches from their offline queue: the same play
    # twice is one scrobble.
    create unique_index(:scrobbles, [:user_id, :track_id, :played_at])
    create index(:scrobbles, [:played_at])
    create index(:scrobbles, [:user_id, :played_at])
    create index(:scrobbles, [:artist_id])
    create index(:scrobbles, [:album_id])

    # One row per user: what they're listening to right now.
    create table(:now_playing, primary_key: false) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), primary_key: true
      add :track_id, references(:tracks, type: :uuid, on_delete: :delete_all), null: false
      add :album_id, references(:albums, type: :uuid, on_delete: :nilify_all)
      add :started_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
    end

    # Bearer tokens for scrobbling clients. Only a SHA-256 of the token is
    # kept; the plaintext is shown once, when minted.
    create table(:scrobble_tokens, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :label, :string
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scrobble_tokens, [:token_hash])
    create index(:scrobble_tokens, [:user_id])
  end
end

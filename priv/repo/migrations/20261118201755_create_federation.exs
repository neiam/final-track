defmodule FinalTrack.Repo.Migrations.CreateFederation do
  use Ecto.Migration

  # ActivityPub (FinalTrack.Federation): one optional fediverse account per
  # user, its followers, what it has posted, the server's own actor, and a
  # cache of remote actors (for their inboxes and signature keys).
  def change do
    create table(:fediverse_accounts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :username, :citext, null: false
      add :enabled, :boolean, null: false, default: false
      add :public_key_pem, :text, null: false
      add :private_key_pem, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fediverse_accounts, [:user_id])
    create unique_index(:fediverse_accounts, [:username])

    create table(:fediverse_followers, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :account_id, references(:fediverse_accounts, type: :uuid, on_delete: :delete_all),
        null: false

      add :actor_id, :text, null: false
      add :inbox, :text, null: false
      add :shared_inbox, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fediverse_followers, [:account_id, :actor_id])
    create index(:fediverse_followers, [:actor_id])

    # One per published play. The Note is built from the scrobble whenever
    # it's served or sent, so it always reflects the play's privacy now.
    create table(:fediverse_posts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :account_id, references(:fediverse_accounts, type: :uuid, on_delete: :delete_all),
        null: false

      add :scrobble_id, references(:scrobbles, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:fediverse_posts, [:scrobble_id])
    create index(:fediverse_posts, [:account_id, :inserted_at])

    # The server's own Application actor: signs fetches made on nobody's
    # behalf (resolving a follower before any account is involved), as
    # authorized-fetch servers refuse unsigned GETs. One row.
    create table(:fediverse_instance_actor, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :public_key_pem, :text, null: false
      add :private_key_pem, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:fediverse_remote_actors, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :ap_id, :text, null: false
      add :inbox, :text, null: false
      add :shared_inbox, :text
      add :public_key_id, :text
      add :public_key_pem, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fediverse_remote_actors, [:ap_id])
    create index(:fediverse_remote_actors, [:public_key_id])
  end
end

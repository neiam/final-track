defmodule FinalTrack.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  # Single-use registration invites. Only a SHA-256 of the link token is
  # kept (like users_tokens), so a copy of the database can't be used to
  # register. An invite may be addressed to an email: the link then
  # registers that address only, counted as confirmed.
  def change do
    create table(:invites, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token_hash, :binary, null: false
      add :note, :string
      add :email, :citext
      add :created_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :consumed_by_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :expires_at, :utc_datetime
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:token_hash])
    create index(:invites, [:created_by_id])
  end
end

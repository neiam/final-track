defmodule FinalTrack.Repo.Migrations.AddIsAdminToUsers do
  use Ecto.Migration

  # Admins edit instance settings. Granted by the OIDC admin group on
  # sign-in, or by `FinalTrack.Release.admin/2`.
  def change do
    alter table(:users) do
      add :is_admin, :boolean, null: false, default: false
    end
  end
end

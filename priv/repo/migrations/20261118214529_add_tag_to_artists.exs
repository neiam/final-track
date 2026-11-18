defmodule FinalTrack.Repo.Migrations.AddTagToArtists do
  use Ecto.Migration

  # Each artist's name as a hashtag ("Pink Floyd" -> "pinkfloyd"), so
  # /tags/pinkfloyd can find its posts by index. Set on insert by
  # FinalTrack.Catalog.ensure_artist!/1; existing rows are backfilled here
  # with the same rule (written out, not called, so this migration doesn't
  # change if the app's code does).
  def up do
    alter table(:artists) do
      add :tag, :string
    end

    create index(:artists, [:tag])

    flush()

    %{rows: rows} = repo().query!("SELECT id, name FROM artists")

    for [id, name] <- rows do
      tag = name |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
      tag = if tag =~ ~r/\p{L}/u, do: tag, else: nil
      repo().query!("UPDATE artists SET tag = $1 WHERE id = $2", [tag, id])
    end
  end

  def down do
    alter table(:artists) do
      remove :tag
    end
  end
end

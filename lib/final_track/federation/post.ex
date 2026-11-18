defmodule FinalTrack.Federation.Post do
  @moduledoc """
  A play an account has published. Its Note is built from the scrobble each
  time it's needed (`FinalTrack.Federation.Objects`), never stored.
  """
  use FinalTrack.Schema

  schema "fediverse_posts" do
    belongs_to :account, FinalTrack.Federation.Account
    belongs_to :scrobble, FinalTrack.Scrobbles.Scrobble

    timestamps(updated_at: false)
  end
end

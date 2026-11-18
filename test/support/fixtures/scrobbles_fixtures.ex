defmodule FinalTrack.ScrobblesFixtures do
  @moduledoc "Plays, tokens and images for tests."

  alias FinalTrack.Scrobbles

  @doc """
  Records one play for `user` through the real path (validation, catalog,
  dedup). `attrs` use the API's string keys; `"timestamp"` defaults to now.
  """
  def play_fixture(user, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          "artist" => "Pink Floyd",
          "track" => "Time",
          "album" => "The Dark Side of the Moon",
          "timestamp" => System.os_time(:second)
        },
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      )

    {:ok, play} = Scrobbles.validate_play(params)
    Scrobbles.record_plays(user, [play])
    play
  end

  @doc "Unix seconds for a UTC datetime given as an ISO string."
  def unix(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt)
  end

  def token_fixture(user, label \\ "test phone") do
    {:ok, plaintext, token} = Scrobbles.create_token(user, %{"label" => label})
    {plaintext, token}
  end

  @doc "A real 1x1 PNG."
  def png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )
  end

  @doc "The smallest thing that sniffs as a JPEG."
  def jpeg_bytes, do: <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<0>>, 64)
end

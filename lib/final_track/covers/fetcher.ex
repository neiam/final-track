defmodule FinalTrack.Covers.Fetcher do
  @moduledoc """
  Looks up an album's cover: MusicBrainz search for the release group by
  title and artist, then its front image from the Cover Art Archive. Both
  are free and need no key.

  MusicBrainz asks for a descriptive User-Agent and at most about one
  request a second; `FinalTrack.Covers.Queue` does the pacing. Set the
  agent (ideally with a contact URL or address for the operator) with
  `config :final_track, FinalTrack.Covers, user_agent: "..."`.

  `config :final_track, FinalTrack.Covers, req_options: [...]` is merged
  into every request (tests use it to plug in `Req.Test`).
  """

  alias FinalTrack.Catalog.Album

  @musicbrainz "https://musicbrainz.org/ws/2/release-group/"
  @coverartarchive "https://coverartarchive.org/release-group/"
  # MusicBrainz scores matches 0-100; below this it's a guess.
  @min_score 90

  @doc """
  `{:ok, %{bytes: binary, mbid: id}}`, `{:error, :no_match}` when
  MusicBrainz knows no such album, `{:error, {:no_cover, mbid}}` when it does
  but the archive has no front cover, or another `{:error, reason}`.
  """
  def fetch(%Album{} = album) do
    with {:ok, mbid} <- find_release_group(album.title, album.artist.name),
         {:ok, bytes} <- front_cover(mbid) do
      {:ok, %{bytes: bytes, mbid: mbid}}
    end
  end

  # Players often put the whole credit in the artist field ("Justice & Tame
  # Impala", "X feat. Y"), and MusicBrainz knows the album under the main
  # artist. The full name goes first, so a duo whose name has an "&" in it
  # (Simon & Garfunkel) is still found as itself.
  defp find_release_group(title, artist) do
    artist
    |> artist_candidates()
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :no_match}, fn {candidate, i}, _ ->
      # Each extra search is another MusicBrainz request: keep to its pace.
      if i > 0, do: Process.sleep(pause_ms())

      case release_group(title, candidate) do
        {:error, :no_match} = miss -> {:cont, miss}
        other -> {:halt, other}
      end
    end)
  end

  @separators ~r/\s+(?:&|feat\.?|ft\.?|featuring|with|x|vs\.?|and)\s+|\s*[,;\/]\s*/iu

  @doc """
  The artist names worth searching for: the full credit, then its main
  artist when the credit names several ("Justice & Tame Impala" → "Justice").
  """
  def artist_candidates(artist) do
    main = @separators |> Regex.split(artist, parts: 2) |> hd() |> String.trim()
    Enum.uniq(Enum.reject([artist, main], &(&1 == "")))
  end

  defp pause_ms,
    do:
      Application.get_env(:final_track, FinalTrack.Covers, []) |> Keyword.get(:interval_ms, 1100)

  @doc "The best MusicBrainz release-group id for an album, if any."
  def release_group(title, artist) do
    query = ~s(releasegroup:"#{escape(title)}" AND artist:"#{escape(artist)}")

    case Req.get(req(), url: @musicbrainz, params: [query: query, fmt: "json", limit: 5]) do
      {:ok, %{status: 200, body: %{"release-groups" => groups}}} ->
        case Enum.find(groups, &((&1["score"] || 0) >= @min_score)) do
          %{"id" => id} -> {:ok, id}
          nil -> {:error, :no_match}
        end

      {:ok, %{status: status}} ->
        {:error, {:musicbrainz, status}}

      {:error, exception} ->
        {:error, {:musicbrainz, Exception.message(exception)}}
    end
  end

  @doc "The front cover (500px) of a release group from the Cover Art Archive."
  def front_cover(mbid) do
    case Req.get(req(), url: @coverartarchive <> mbid <> "/front-500", decode_body: false) do
      {:ok, %{status: 200, body: bytes}} when is_binary(bytes) -> {:ok, bytes}
      {:ok, %{status: 404}} -> {:error, {:no_cover, mbid}}
      {:ok, %{status: status}} -> {:error, {:coverartarchive, status}}
      {:error, exception} -> {:error, {:coverartarchive, Exception.message(exception)}}
    end
  end

  # Lucene phrase: drop what would end the phrase or escape out of it.
  defp escape(text), do: String.replace(text, ~r/["\\]/, " ")

  defp req do
    config = Application.get_env(:final_track, FinalTrack.Covers, [])

    Req.new(
      headers: [{"user-agent", Keyword.get(config, :user_agent, "FinalTrack/0.1")}],
      receive_timeout: 15_000,
      retry: :transient,
      max_retries: 2
    )
    |> Req.merge(Keyword.get(config, :req_options, []))
  end
end

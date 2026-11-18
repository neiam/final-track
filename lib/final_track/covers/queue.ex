defmodule FinalTrack.Covers.Queue do
  @moduledoc """
  Runs cover lookups one at a time, `interval_ms` apart (default 1100), to
  stay inside MusicBrainz's rate limit however many albums arrive at once.
  An album already waiting isn't queued twice.

  Outcomes go out on the `"covers"` PubSub topic (see `FinalTrack.Covers`).
  """
  use GenServer

  require Logger

  alias FinalTrack.Covers

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues a lookup for the album with `album_id`."
  def enqueue(album_id), do: GenServer.cast(__MODULE__, {:enqueue, album_id})

  @impl true
  def init(_opts) do
    {:ok, %{queue: :queue.new(), waiting: MapSet.new(), busy?: false}}
  end

  @impl true
  def handle_cast({:enqueue, id}, state) do
    if MapSet.member?(state.waiting, id) do
      {:noreply, state}
    else
      state = %{state | queue: :queue.in(id, state.queue), waiting: MapSet.put(state.waiting, id)}
      {:noreply, maybe_start(state)}
    end
  end

  @impl true
  def handle_info(:work, state) do
    case :queue.out(state.queue) do
      {{:value, id}, queue} ->
        run(id)
        Process.send_after(self(), :work, interval())
        {:noreply, %{state | queue: queue, waiting: MapSet.delete(state.waiting, id)}}

      {:empty, _} ->
        {:noreply, %{state | busy?: false}}
    end
  end

  # One bad lookup must not take the queue, and everything waiting in it,
  # down with it.
  defp run(id) do
    Covers.fetch_cover_now(id)
  rescue
    exception ->
      Logger.error(
        "cover lookup for album #{id} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
  end

  defp maybe_start(%{busy?: true} = state), do: state

  defp maybe_start(state) do
    send(self(), :work)
    %{state | busy?: true}
  end

  defp interval do
    Application.get_env(:final_track, FinalTrack.Covers, []) |> Keyword.get(:interval_ms, 1100)
  end
end

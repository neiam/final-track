defmodule FinalTrackWeb.ArtistLive.Show do
  @moduledoc "One artist, all time: plays, their albums (with covers) and most played tracks."
  use FinalTrackWeb, :live_view

  alias FinalTrack.{Catalog, Charts, Covers, Privacy}
  alias FinalTrack.Catalog.Artist
  alias FinalTrack.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Artist{} = artist <- Repo.get(Artist, id) do
      if connected?(socket), do: Covers.subscribe()

      {:ok,
       socket
       |> assign(:page_title, artist.name)
       |> assign(:artist, artist)
       |> load()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That artist doesn't exist.")
         |> push_navigate(to: ~p"/charts")}
    end
  end

  defp load(socket) do
    %{artist: artist, current_scope: %{user: user}} = socket.assigns
    audience = Charts.audience(user)
    tracks = Charts.artist_tracks(artist, audience)

    socket
    |> assign(:summary, Charts.summary(artist, audience))
    |> assign(:albums, Charts.artist_albums(artist, audience))
    |> assign(:tracks, tracks)
    |> assign(:private?, Privacy.private?(user, artist))
    |> assign(:private_tracks, Privacy.private_track_ids(user, Enum.map(tracks, & &1.track.id)))
  end

  @impl true
  def handle_event("toggle_private", _params, socket) do
    %{artist: artist, private?: private?, current_scope: %{user: user}} = socket.assigns
    :ok = if private?, do: Privacy.unmark(user, artist), else: Privacy.mark(user, artist)
    {:noreply, load(socket)}
  end

  def handle_event("toggle_track_private", %{"id" => id}, socket) do
    %{private_tracks: private, current_scope: %{user: user}} = socket.assigns
    track = Catalog.get_track!(id)

    :ok =
      if MapSet.member?(private, track.id),
        do: Privacy.unmark(user, track),
        else: Privacy.mark(user, track)

    {:noreply, load(socket)}
  end

  # A cover changed somewhere; cheap enough to reload.
  @impl true
  def handle_info({:cover_updated, _id}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8 motion-safe:animate-[fade-in_200ms_ease-out]">
        <header>
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Artist</p>
          <h1 id="artist-name" class="mt-1 text-3xl font-bold tracking-tight sm:text-5xl">
            {@artist.name}
          </h1>
          <p id="artist-stats" class="mt-2 text-sm text-base-content/70">
            <span class="font-mono">{plays(@summary.plays)}</span>
            by <span class="font-mono">{@summary.listeners}</span>
            {if @summary.listeners == 1, do: "listener", else: "listeners"}
            <span :if={@summary.last}>· last played {ago(@summary.last)}</span>
          </p>
          <div class="mt-3">
            <.private_toggle
              id="artist-private"
              private?={@private?}
              event="toggle_private"
              what="artist"
            />
          </div>
        </header>

        <section :if={@albums != []} id="artist-albums">
          <h2 class="mb-3 flex items-center gap-2 font-semibold">
            <.icon name="hero-square-3-stack-3d-micro" class="size-4 text-accent" /> Albums
          </h2>
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
            <.link
              :for={%{album: album, plays: n} <- @albums}
              id={"album-#{album.id}"}
              navigate={~p"/albums/#{album.id}"}
              class="group space-y-2"
            >
              <.cover
                album={album}
                class="aspect-square w-full transition duration-200 group-hover:-translate-y-0.5 group-hover:shadow-lg"
              />
              <div class="min-w-0">
                <p class="truncate text-sm font-medium group-hover:text-primary">{album.title}</p>
                <p class="font-mono text-xs text-base-content/60">{plays(n)}</p>
              </div>
            </.link>
          </div>
        </section>

        <div class="max-w-2xl">
          <.chart_list
            id="artist-tracks"
            title="Top tracks"
            icon="hero-musical-note-micro"
            rows={@tracks}
          >
            <:row :let={row}>
              <p class="min-w-0 flex-1 truncate font-medium">{row.track.title}</p>
              <button
                :if={!@private?}
                type="button"
                id={"track-private-#{row.track.id}"}
                phx-click="toggle_track_private"
                phx-value-id={row.track.id}
                class={[
                  "btn btn-ghost btn-xs transition",
                  if(MapSet.member?(@private_tracks, row.track.id),
                    do: "text-warning",
                    else: "opacity-0 group-hover:opacity-60 focus:opacity-100"
                  )
                ]}
                title={
                  if MapSet.member?(@private_tracks, row.track.id),
                    do: "Private: only you see your plays of this track. Click to share.",
                    else: "Keep my plays of this track private"
                }
              >
                <.icon
                  name={
                    if MapSet.member?(@private_tracks, row.track.id),
                      do: "hero-lock-closed-micro",
                      else: "hero-lock-open-micro"
                  }
                  class="size-3.5"
                />
              </button>
            </:row>
          </.chart_list>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

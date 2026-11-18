defmodule FinalTrackWeb.AlbumLive.Show do
  @moduledoc """
  One album: its cover, how much it's played, and its tracks as played.

  The cover can be uploaded (drop or pick a file; stored as soon as the
  upload finishes), fetched from MusicBrainz and the Cover Art Archive
  (queued; the result arrives over PubSub), or removed.
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.{Catalog, Charts, Covers, Privacy}
  alias FinalTrack.Covers.Image

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Catalog.get_album(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That album doesn't exist.")
         |> push_navigate(to: ~p"/charts")}

      album ->
        if connected?(socket), do: Covers.subscribe()

        {:ok,
         socket
         |> assign(:page_title, album.title)
         |> assign(:album, album)
         |> assign(:fetching?, false)
         |> load_stats()
         |> allow_upload(:cover,
           accept: ~w(.jpg .jpeg .png .webp),
           max_entries: 1,
           max_file_size: Image.max_bytes(),
           auto_upload: true,
           progress: &handle_progress/3
         )}
    end
  end

  defp load_stats(socket) do
    %{album: album, current_scope: %{user: user}} = socket.assigns
    audience = Charts.audience(user)
    tracks = Charts.album_tracks(album, audience)

    socket
    |> assign(:summary, Charts.summary(album, audience))
    |> assign(:tracks, tracks)
    |> assign(:private?, Privacy.private?(user, album))
    |> assign(:artist_private?, Privacy.private?(user, album.artist))
    |> assign(:private_tracks, Privacy.private_track_ids(user, Enum.map(tracks, & &1.track.id)))
  end

  # The form's phx-change; the upload itself goes on in the background.
  @impl true
  def handle_event("validate_cover", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :cover, ref)}

  def handle_event("fetch_cover", _params, socket) do
    Covers.request_fetch(socket.assigns.album)
    {:noreply, assign(socket, :fetching?, true)}
  end

  def handle_event("toggle_private", _params, socket) do
    %{album: album, private?: private?, current_scope: %{user: user}} = socket.assigns
    :ok = if private?, do: Privacy.unmark(user, album), else: Privacy.mark(user, album)
    {:noreply, load_stats(socket)}
  end

  def handle_event("toggle_track_private", %{"id" => id}, socket) do
    %{private_tracks: private, current_scope: %{user: user}} = socket.assigns
    track = Catalog.get_track!(id)

    :ok =
      if MapSet.member?(private, track.id),
        do: Privacy.unmark(user, track),
        else: Privacy.mark(user, track)

    {:noreply, load_stats(socket)}
  end

  def handle_event("remove_cover", _params, socket) do
    {:ok, album} = Covers.remove(socket.assigns.album)
    {:noreply, socket |> assign(:album, album) |> put_flash(:info, "Cover removed.")}
  end

  defp handle_progress(:cover, %{done?: true} = entry, socket) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Covers.put_upload(socket.assigns.album, path)}
      end)

    case result do
      {:ok, album} ->
        {:noreply, socket |> assign(:album, album) |> put_flash(:info, "Cover updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Covers.describe_failure(reason))}
    end
  end

  defp handle_progress(:cover, _entry, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:cover_updated, id}, %{assigns: %{album: %{id: id}}} = socket) do
    socket =
      if socket.assigns.fetching?,
        do: put_flash(socket, :info, "Cover found."),
        else: socket

    {:noreply, assign(socket, album: Catalog.get_album!(id), fetching?: false)}
  end

  def handle_info({:cover_fetch_failed, id, reason}, %{assigns: %{album: %{id: id}}} = socket) do
    {:noreply,
     socket
     |> assign(:fetching?, false)
     |> put_flash(:error, Covers.describe_failure(reason))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="grid gap-8 md:grid-cols-[18rem_1fr] motion-safe:animate-[fade-in_200ms_ease-out]">
        <div class="space-y-3">
          <form id="cover-form" phx-change="validate_cover" phx-submit="validate_cover">
            <label
              for={@uploads.cover.ref}
              phx-drop-target={@uploads.cover.ref}
              class="group relative block cursor-pointer"
              title="Drop an image here, or click to choose one"
            >
              <.cover
                album={@album}
                id="album-cover"
                class="aspect-square w-full shadow-lg transition group-hover:brightness-90 group-[.phx-drop-target-active]:ring-2 group-[.phx-drop-target-active]:ring-primary"
              />
              <span class="absolute inset-0 flex items-center justify-center rounded-box bg-base-100/70 opacity-0 backdrop-blur-sm transition group-hover:opacity-100">
                <span class="flex items-center gap-2 text-sm font-medium">
                  <.icon name="hero-arrow-up-tray-micro" class="size-4" /> Upload a cover
                </span>
              </span>
              <span
                :if={@fetching?}
                id="cover-fetching"
                class="absolute inset-0 flex items-center justify-center rounded-box bg-base-100/70 backdrop-blur-sm"
              >
                <span class="loading loading-spinner loading-md text-primary" />
              </span>
            </label>
            <.live_file_input upload={@uploads.cover} class="sr-only" />
          </form>

          <div :for={entry <- @uploads.cover.entries} id={"upload-#{entry.ref}"} class="space-y-1">
            <div class="flex items-center gap-2 text-xs">
              <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs"
                aria-label="Cancel"
              >
                <.icon name="hero-x-mark-micro" class="size-3" />
              </button>
            </div>
            <progress class="progress progress-primary w-full" value={entry.progress} max="100" />
            <p :for={err <- upload_errors(@uploads.cover, entry)} class="text-xs text-error">
              {upload_error(err)}
            </p>
          </div>
          <p :for={err <- upload_errors(@uploads.cover)} class="text-xs text-error">
            {upload_error(err)}
          </p>

          <div class="flex gap-2">
            <button
              id="fetch-cover"
              type="button"
              phx-click="fetch_cover"
              disabled={@fetching?}
              class="btn btn-sm btn-primary flex-1"
            >
              <.icon name="hero-magnifying-glass-micro" class="size-4" />
              {if @album.cover_key, do: "Fetch again", else: "Fetch cover"}
            </button>
            <button
              :if={@album.cover_key}
              id="remove-cover"
              type="button"
              phx-click="remove_cover"
              data-confirm="Remove this cover?"
              class="btn btn-sm btn-ghost text-error"
              aria-label="Remove cover"
            >
              <.icon name="hero-trash-micro" class="size-4" />
            </button>
          </div>
          <p class="text-xs text-base-content/60">
            <%= case @album.cover_source do %>
              <% "upload" -> %>
                Uploaded cover.
              <% "coverartarchive" -> %>
                From the <a
                  href={"https://musicbrainz.org/release-group/#{@album.mbid}"}
                  class="link"
                  target="_blank"
                  rel="noopener"
                >
                  Cover Art Archive
                </a>.
              <% _ -> %>
                Drop a JPEG, PNG or WebP on the cover, or fetch one from MusicBrainz.
            <% end %>
          </p>
        </div>

        <div class="min-w-0 space-y-6">
          <div>
            <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Album</p>
            <h1 id="album-title" class="mt-1 text-3xl font-bold tracking-tight sm:text-4xl">
              {@album.title}
            </h1>
            <.link
              navigate={~p"/artists/#{@album.artist.id}"}
              id="album-artist"
              class="mt-1 inline-block text-lg text-base-content/80 hover:text-primary"
            >
              {@album.artist.name}
            </.link>
            <div class="mt-3">
              <.private_toggle
                id="album-private"
                private?={@private?}
                inherited?={@artist_private?}
                event="toggle_private"
                what="album"
              />
            </div>
          </div>

          <dl id="album-stats" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <.stat label="Plays" value={@summary.plays} />
            <.stat label="Listeners" value={@summary.listeners} />
            <.stat label="First played" value={@summary.first && ago(@summary.first)} />
            <.stat label="Last played" value={@summary.last && ago(@summary.last)} />
          </dl>

          <.chart_list
            id="album-tracks"
            title="Tracks"
            icon="hero-musical-note-micro"
            rows={@tracks}
            empty="No plays of this album yet."
          >
            <:row :let={row}>
              <p class="min-w-0 flex-1 truncate font-medium">{row.track.title}</p>
              <button
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

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200 px-3 py-2">
      <dt class="text-xs uppercase tracking-wide text-base-content/60">{@label}</dt>
      <dd class="mt-0.5 font-mono text-lg">{@value || "—"}</dd>
    </div>
    """
  end

  defp upload_error(:too_large), do: "That image is too large (8 MB at most)."
  defp upload_error(:not_accepted), do: "Use a JPEG, PNG or WebP image."
  defp upload_error(:too_many_files), do: "One image at a time."
  defp upload_error(_), do: "That upload didn't work."
end

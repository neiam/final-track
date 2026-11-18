defmodule FinalTrackWeb.HomeLive do
  @moduledoc """
  The landing page: a live grid of the latest plays, album art first.

  Public. Signed-out visitors see what was played, never who played it,
  and nothing anyone has marked private (`FinalTrack.Privacy` with no
  viewer). Members also see who played each track, and tiles link to the
  album or artist.

  New plays, now-playing changes and covers arrive over PubSub and reload
  the grid (debounced); tiles that weren't there before animate in. The
  "5m ago" labels are refreshed every minute.
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.Accounts.User
  alias FinalTrack.{Charts, Covers, Scrobbles}

  @size 48
  @refresh_ms 400
  @tick_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Scrobbles.subscribe()
      Covers.subscribe()
      :timer.send_interval(@tick_ms, :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Playing lately")
     |> assign(:refresh_timer, nil)
     |> assign(:known, nil)
     |> load()}
  end

  defp viewer(%{assigns: %{current_scope: %{user: %User{} = user}}}), do: user
  defp viewer(_socket), do: nil

  defp load(socket) do
    viewer = viewer(socket)
    plays = Scrobbles.recent(Charts.audience(viewer), @size)
    ids = MapSet.new(plays, & &1.id)

    # Fresh: not in the grid last time. Nothing is fresh on first load.
    fresh =
      if socket.assigns.known,
        do: MapSet.difference(ids, socket.assigns.known),
        else: MapSet.new()

    socket
    |> assign(:known, ids)
    |> assign(:fresh, fresh)
    |> assign(:empty?, plays == [])
    |> assign(:now_playing, Scrobbles.now_playing(viewer))
    |> stream(:plays, plays, reset: true)
  end

  @impl true
  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(:refresh_timer, nil) |> load()}

  def handle_info(_pubsub_message, %{assigns: %{refresh_timer: nil}} = socket),
    do:
      {:noreply,
       assign(socket, :refresh_timer, Process.send_after(self(), :refresh, @refresh_ms))}

  def handle_info(_pubsub_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :member?, match?(%{user: %User{}}, assigns.current_scope))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="mx-auto max-w-7xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="flex items-center gap-2 font-mono text-xs uppercase tracking-[0.25em] text-accent">
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60" />
                <span class="relative inline-flex size-2 rounded-full bg-accent" />
              </span>
              Live
            </p>
            <h1 class="mt-1 text-3xl font-bold tracking-tight sm:text-4xl">Playing lately</h1>
          </div>
          <div class="flex gap-2">
            <%= if @member? do %>
              <.link navigate={~p"/charts"} class="btn btn-sm btn-primary" id="home-charts">
                <.icon name="hero-chart-bar-micro" class="size-4" /> Charts
              </.link>
              <.link navigate={~p"/artists"} class="btn btn-sm btn-ghost">Library</.link>
            <% else %>
              <.link navigate={~p"/about"} class="btn btn-sm btn-ghost" id="home-about">
                What is this?
              </.link>
              <.link navigate={~p"/users/log-in"} class="btn btn-sm btn-primary">Log in</.link>
            <% end %>
          </div>
        </header>

        <section :if={@now_playing != []} id="listening-now" class="space-y-2">
          <h2 class="flex items-center gap-2 text-sm font-semibold text-base-content/70">
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-75" />
              <span class="relative inline-flex size-2 rounded-full bg-success" />
            </span>
            Listening now
          </h2>
          <div class="flex gap-3 overflow-x-auto pb-1">
            <div
              :for={np <- @now_playing}
              id={"now-#{np.user_id}"}
              class="flex w-72 shrink-0 items-center gap-3 rounded-box border border-success/30 bg-base-200 p-2 pr-4 motion-safe:animate-[fade-in_300ms_ease-out]"
            >
              <.cover album={np.album} class="size-14" />
              <div class="min-w-0 text-sm">
                <p class="truncate font-medium">{np.track.title}</p>
                <p class="truncate text-xs text-base-content/60">{np.track.artist.name}</p>
                <p :if={@member?} class="truncate text-xs text-success">
                  {User.display_name(np.user)}
                </p>
              </div>
            </div>
          </div>
        </section>

        <div
          id="plays-grid"
          phx-update="stream"
          class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6"
        >
          <div
            id="plays-empty"
            class="col-span-full hidden only:block rounded-box border border-dashed border-base-300 py-24 text-center text-base-content/60"
          >
            <.icon name="hero-musical-note" class="mx-auto mb-2 size-8 opacity-40" />
            <p>Nothing played yet.</p>
          </div>
          <div
            :for={{dom_id, play} <- @streams.plays}
            id={dom_id}
            class={[
              "group relative aspect-square overflow-hidden rounded-box border border-base-300 bg-base-300 shadow-sm transition duration-300 hover:-translate-y-0.5 hover:shadow-xl",
              MapSet.member?(@fresh, play.id) &&
                "ring-2 ring-accent motion-safe:animate-[pop-in_500ms_cubic-bezier(0.2,0.8,0.2,1)]"
            ]}
          >
            <.tile_link play={play} member?={@member?}>
              <div class="absolute inset-0 transition-transform duration-500 group-hover:scale-105">
                <.cover album={play.album} class="size-full rounded-none! border-0!" />
              </div>
              <div class="absolute inset-0 bg-gradient-to-t from-black/85 via-black/20 to-transparent opacity-90 transition-opacity group-hover:opacity-100" />
              <span class="absolute left-2 top-2 rounded-full bg-black/50 px-2 py-0.5 font-mono text-[10px] text-white/90 backdrop-blur-sm">
                {ago(play.played_at)}
              </span>
              <span
                :if={@member?}
                class="absolute right-2 top-2 flex size-6 items-center justify-center rounded-full bg-black/50 font-mono text-[11px] font-bold text-white/90 backdrop-blur-sm"
                title={User.display_name(play.user)}
              >
                {play.user |> User.display_name() |> String.first() |> String.upcase()}
              </span>
              <div class="absolute inset-x-0 bottom-0 p-3 text-white">
                <p class="truncate text-sm font-semibold leading-tight drop-shadow">
                  {play.track.title}
                </p>
                <p class="truncate text-xs text-white/80">{play.track.artist.name}</p>
                <p
                  :if={play.album}
                  class="max-h-0 truncate text-xs text-white/60 opacity-0 transition-all duration-300 group-hover:max-h-5 group-hover:opacity-100"
                >
                  {play.album.title}
                </p>
                <p
                  :if={@member?}
                  class="max-h-0 truncate text-xs text-accent opacity-0 transition-all duration-300 group-hover:max-h-5 group-hover:opacity-100"
                >
                  {User.display_name(play.user)}
                </p>
              </div>
            </.tile_link>
          </div>
        </div>

        <footer class="pt-6 text-center">
          <p class="flex items-center justify-center gap-2 font-mono text-xs uppercase tracking-[0.25em] text-base-content/60">
            <.link navigate={~p"/about"} class="hover:text-base-content">About</.link>
            <span class="opacity-50">·</span>
            <span>a</span>
            <span class="font-bold tracking-[0.16em]" style="color: oklch(96% 0.058 96);">
              <a href="https://neiam.org">NEIAM</a>
            </span>
            <span>production</span>
          </p>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  # Members can open the album (or, without one, the artist); visitors can't
  # (those pages are members-only), so their tiles aren't links.
  attr :play, :map, required: true
  attr :member?, :boolean, required: true
  slot :inner_block, required: true

  defp tile_link(%{member?: true} = assigns) do
    ~H"""
    <.link
      navigate={
        if @play.album,
          do: ~p"/albums/#{@play.album.id}",
          else: ~p"/artists/#{@play.track.artist.id}"
      }
      class="absolute inset-0"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp tile_link(assigns) do
    ~H"""
    <div class="absolute inset-0">{render_slot(@inner_block)}</div>
    """
  end
end

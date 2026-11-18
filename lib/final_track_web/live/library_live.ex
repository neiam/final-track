defmodule FinalTrackWeb.LibraryLive do
  @moduledoc """
  Every artist (`/artists`) or album (`/albums`) that's been played, with
  its numbers: plays, listeners, tracks (and albums) played, first and last
  played.

  URL params (all optional): `q` (search), `sort` (`plays`, `name` or
  `recent`; default plays) and `who` (`everyone`, the default, or `me`).
  Rows are a stream, loaded 50 at a time as you scroll. Others' private
  plays count for nothing here, as everywhere (`FinalTrack.Privacy`).
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.Charts

  @page 50

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    kind = socket.assigns.live_action
    user = socket.assigns.current_scope.user
    who = if params["who"] == "me", do: :me, else: :everyone

    opts = [
      sort: Charts.parse_sort(params["sort"]),
      search: params["q"] |> to_string() |> String.slice(0, 100)
    ]

    audience = Charts.audience(user, if(who == :me, do: user))
    stats = Charts.library_stats(kind, audience, opts)

    {:noreply,
     socket
     |> assign(
       page_title: if(kind == :artists, do: "Artists", else: "Albums"),
       kind: kind,
       who: who,
       opts: opts,
       audience: audience,
       stats: stats,
       search_form: to_form(%{"q" => opts[:search]}, as: :library)
     )
     |> load_page(0, reset: true)}
  end

  defp load_page(socket, offset, stream_opts \\ []) do
    %{kind: kind, audience: audience, opts: opts} = socket.assigns
    rows = fetch(kind, audience, Keyword.merge(opts, limit: @page, offset: offset))

    socket
    |> assign(:offset, offset + length(rows))
    |> assign(:more?, length(rows) == @page)
    |> stream(:rows, Enum.map(rows, &Map.put(&1, :id, row_id(kind, &1))), stream_opts)
  end

  defp fetch(:artists, audience, opts), do: Charts.library_artists(audience, opts)
  defp fetch(:albums, audience, opts), do: Charts.library_albums(audience, opts)

  defp row_id(:artists, row), do: row.artist.id
  defp row_id(:albums, row), do: row.album.id

  @impl true
  def handle_event("load_more", _params, %{assigns: %{more?: true}} = socket),
    do: {:noreply, load_page(socket, socket.assigns.offset)}

  def handle_event("load_more", _params, socket), do: {:noreply, socket}

  def handle_event("search", %{"library" => %{"q" => q}}, socket),
    do: {:noreply, push_patch(socket, to: library_path(socket.assigns, q: q))}

  defp library_path(assigns, changes) do
    params =
      %{q: assigns.opts[:search], sort: assigns.opts[:sort], who: assigns.who}
      |> Map.merge(Map.new(changes))
      |> Map.reject(fn {k, v} ->
        v in [nil, ""] or {k, v} in [{:sort, :plays}, {:who, :everyone}]
      end)

    case assigns.kind do
      :artists -> ~p"/artists?#{params}"
      :albums -> ~p"/albums?#{params}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6 motion-safe:animate-[fade-in_200ms_ease-out]">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Library</p>
            <div id="library-tabs" class="mt-1 flex items-baseline gap-4" role="tablist">
              <.link
                :for={{kind, label} <- [artists: "Artists", albums: "Albums"]}
                id={"tab-#{kind}"}
                patch={library_path(%{assigns | kind: kind}, q: nil)}
                aria-selected={to_string(@kind == kind)}
                class={[
                  "text-3xl font-bold tracking-tight transition-colors",
                  if(@kind == kind,
                    do: "text-base-content",
                    else: "text-base-content/30 hover:text-base-content/60"
                  )
                ]}
              >
                {label}
              </.link>
            </div>
            <p id="library-count" class="mt-1 text-sm text-base-content/70">
              <span class="font-mono">{@stats.count}</span>
              {if @kind == :artists, do: "artists", else: "albums"}
              {if @who == :me, do: "you've played", else: "played"}
              <span :if={@opts[:search] != ""}>
                matching “<span class="font-medium">{@opts[:search]}</span>”
              </span>
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.form
              for={@search_form}
              id="library-search"
              phx-change="search"
              phx-submit="search"
              class="relative"
            >
              <.icon
                name="hero-magnifying-glass-micro"
                class="pointer-events-none absolute left-2.5 top-1/2 z-10 size-4 -translate-y-1/2 text-base-content/50"
              />
              <input
                type="search"
                name={@search_form[:q].name}
                value={@search_form[:q].value}
                placeholder={
                  if @kind == :artists, do: "Find an artist", else: "Find an album or artist"
                }
                phx-debounce="250"
                autocomplete="off"
                class="input input-sm w-56 pl-8"
              />
            </.form>

            <div id="library-sort" class="join">
              <.link
                :for={{sort, label} <- [plays: "Most played", name: "A–Z", recent: "Recent"]}
                id={"sort-#{sort}"}
                patch={library_path(assigns, sort: sort)}
                class={[
                  "btn btn-sm join-item",
                  if(@opts[:sort] == sort, do: "btn-primary", else: "btn-ghost")
                ]}
              >
                {label}
              </.link>
            </div>

            <div id="who-toggle" class="join">
              <.link
                :for={{who, label} <- [everyone: "Everyone", me: "Me"]}
                id={"who-#{who}"}
                patch={library_path(assigns, who: who)}
                class={[
                  "btn btn-sm join-item",
                  if(@who == who, do: "btn-secondary", else: "btn-ghost")
                ]}
              >
                {label}
              </.link>
            </div>
          </div>
        </header>

        <div class="overflow-hidden rounded-box border border-base-300 bg-base-200">
          <div class="hidden grid-cols-[minmax(0,1fr)_10rem_5rem_5rem_7rem] gap-4 border-b border-base-300 px-4 py-2 text-xs uppercase tracking-wide text-base-content/60 md:grid">
            <span>{if @kind == :artists, do: "Artist", else: "Album"}</span>
            <span>Plays</span>
            <span class="text-right">Listeners</span>
            <span class="text-right">{if @kind == :artists, do: "Albums", else: "Tracks"}</span>
            <span class="text-right">Last played</span>
          </div>

          <ul
            id="library-rows"
            phx-update="stream"
            phx-viewport-bottom={@more? && "load_more"}
            class="divide-y divide-base-300"
          >
            <li
              id="library-empty"
              class="hidden only:block px-4 py-12 text-center text-sm text-base-content/60"
            >
              <%= if @opts[:search] != "" do %>
                Nothing matches “{@opts[:search]}”.
              <% else %>
                Nothing played yet.
                <.link navigate={~p"/users/scrobbling"} class="link link-primary">
                  Connect a scrobbler
                </.link>
                to get started.
              <% end %>
            </li>
            <li
              :for={{dom_id, row} <- @streams.rows}
              id={dom_id}
              class="group grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1 px-4 py-2.5 transition-colors hover:bg-base-300/50 md:grid-cols-[minmax(0,1fr)_10rem_5rem_5rem_7rem]"
            >
              <%= if @kind == :artists do %>
                <.link
                  navigate={~p"/artists/#{row.artist.id}"}
                  class="flex min-w-0 items-center gap-3"
                >
                  <span class="flex size-9 shrink-0 items-center justify-center rounded-box bg-base-300 font-mono text-sm text-base-content/70 transition group-hover:bg-primary group-hover:text-primary-content">
                    {initial(row.artist.name)}
                  </span>
                  <span class="min-w-0">
                    <span class="block truncate font-medium group-hover:text-primary">
                      {row.artist.name}
                    </span>
                    <span class="block truncate text-xs text-base-content/60">
                      {count_label(row.tracks, "track")} · first played {ago(row.first)}
                    </span>
                  </span>
                </.link>
              <% else %>
                <.link navigate={~p"/albums/#{row.album.id}"} class="flex min-w-0 items-center gap-3">
                  <.cover album={row.album} class="size-10 transition group-hover:shadow-md" />
                  <span class="min-w-0">
                    <span class="block truncate font-medium group-hover:text-primary">
                      {row.album.title}
                    </span>
                    <span class="block truncate text-xs text-base-content/60">
                      {row.album.artist.name}
                    </span>
                  </span>
                </.link>
              <% end %>

              <div class="flex items-center gap-2">
                <div class="hidden h-1.5 flex-1 overflow-hidden rounded-full bg-base-300 md:block">
                  <div
                    class="h-full rounded-full bg-primary transition-[width] duration-500"
                    style={"width: #{bar(row.plays, @stats.max_plays)}%"}
                  />
                </div>
                <span class="w-12 text-right font-mono text-sm tabular-nums">{row.plays}</span>
              </div>
              <span class="hidden text-right font-mono text-sm tabular-nums text-base-content/70 md:block">
                {row.listeners}
              </span>
              <span class="hidden text-right font-mono text-sm tabular-nums text-base-content/70 md:block">
                {if @kind == :artists, do: row.albums, else: row.tracks}
              </span>
              <span class="col-span-2 text-xs text-base-content/60 md:col-span-1 md:text-right md:font-mono">
                <span class="md:hidden">
                  {count_label(row.listeners, "listener")} · last played
                </span>
                {ago(row.last)}
              </span>
            </li>
          </ul>
        </div>

        <p :if={@more?} id="library-more" class="flex justify-center">
          <button type="button" phx-click="load_more" class="btn btn-ghost btn-sm">
            <span class="loading loading-dots loading-sm phx-click-loading:inline-block hidden" />
            Load more
          </button>
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp initial(name), do: name |> String.first() |> String.upcase()

  defp bar(_plays, 0), do: 0
  defp bar(plays, max), do: max(round(plays / max * 100), 2)

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(n, noun), do: "#{n} #{noun}s"
end

defmodule FinalTrackWeb.ChartsLive do
  @moduledoc """
  Popularity by day, week, month or year: top artists, albums and tracks,
  plays over the period, who's listening now and the latest plays.

  URL params (all optional): `period` (`day|week|month|year`, default
  week), `date` (any `YYYY-MM-DD` inside the period, default today) and
  `who` (`everyone`, the default, or `me`). Periods follow the browser's
  time zone, sent as the `tz` connect param from app.js.

  Updates live: new scrobbles, now-playing changes and covers trigger a
  (debounced) reload.
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.{Charts, Covers, Scrobbles}
  alias FinalTrack.Charts.Period

  @refresh_ms 400

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Scrobbles.subscribe()
      Covers.subscribe()
    end

    zone =
      if connected?(socket),
        do: Charts.time_zone(get_connect_params(socket)["tz"]),
        else: "Etc/UTC"

    {:ok,
     socket
     |> assign(:page_title, "Charts")
     |> assign(:zone, zone)
     |> assign(:refresh_timer, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    unit = Period.parse_unit(params["period"])
    today = Charts.today(socket.assigns.zone)

    date =
      case Date.from_iso8601(params["date"] || "") do
        {:ok, date} -> date
        _ -> today
      end

    who = if params["who"] == "me", do: :me, else: :everyone

    {:noreply,
     socket
     |> assign(period: Period.containing(unit, date), today: today, who: who)
     |> load()}
  end

  @impl true
  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(:refresh_timer, nil) |> load()}

  def handle_info(_pubsub_message, %{assigns: %{refresh_timer: nil}} = socket) do
    {:noreply, assign(socket, :refresh_timer, Process.send_after(self(), :refresh, @refresh_ms))}
  end

  def handle_info(_pubsub_message, socket), do: {:noreply, socket}

  defp load(socket) do
    %{period: period, zone: zone, who: who, current_scope: scope} = socket.assigns
    audience = Charts.audience(scope.user, if(who == :me, do: scope.user))

    socket
    |> assign(:total, Charts.total_plays(period, zone, audience))
    |> assign(:timeline, Charts.timeline(period, zone, audience))
    |> assign(:artists, Charts.top_artists(period, zone, audience))
    |> assign(:albums, Charts.top_albums(period, zone, audience))
    |> assign(:tracks, Charts.top_tracks(period, zone, audience))
    |> assign(:now_playing, Scrobbles.now_playing(scope.user))
    |> assign(:recent, Scrobbles.recent(audience, 12))
  end

  defp chart_path(assigns, changes) do
    params =
      %{
        period: assigns.period.unit,
        date: Date.to_iso8601(assigns.period.first),
        who: assigns.who
      }
      |> Map.merge(Map.new(changes))
      |> Map.reject(fn {k, v} -> {k, v} in [{:who, :everyone}] end)

    ~p"/charts?#{params}"
  end

  # A play has no page of its own: its album's, else its artist's.
  defp play_path(%{album: %{id: id}}), do: ~p"/albums/#{id}"
  defp play_path(%{track: %{artist: %{id: id}}}), do: ~p"/artists/#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6 motion-safe:animate-[fade-in_200ms_ease-out]">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Charts</p>
            <h1 id="period-title" class="mt-1 text-3xl font-bold tracking-tight">
              {Period.title(@period)}
            </h1>
            <p class="mt-1 text-sm text-base-content/70">
              <span id="total-plays" class="font-mono">{plays(@total)}</span>
              {if @who == :me, do: "by you", else: "by everyone"}
              <span :if={@zone != "Etc/UTC"} class="opacity-60">· {@zone}</span>
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <div id="period-units" class="join" role="tablist">
              <.link
                :for={unit <- Period.units()}
                id={"period-#{unit}"}
                patch={chart_path(assigns, period: unit)}
                class={[
                  "btn btn-sm join-item capitalize",
                  if(@period.unit == unit, do: "btn-primary", else: "btn-ghost")
                ]}
                aria-selected={to_string(@period.unit == unit)}
              >
                {unit}
              </.link>
            </div>

            <div class="join">
              <.link
                id="period-prev"
                patch={chart_path(assigns, date: Date.to_iso8601(Period.previous(@period).first))}
                class="btn btn-sm btn-ghost join-item"
                aria-label="Previous"
              >
                <.icon name="hero-chevron-left-micro" class="size-4" />
              </.link>
              <.link
                id="period-today"
                patch={chart_path(assigns, date: Date.to_iso8601(@today))}
                class={[
                  "btn btn-sm join-item",
                  if(Period.contains?(@period, @today), do: "btn-disabled", else: "btn-ghost")
                ]}
              >
                Now
              </.link>
              <.link
                id="period-next"
                patch={chart_path(assigns, date: Date.to_iso8601(Period.next(@period).first))}
                class="btn btn-sm btn-ghost join-item"
                aria-label="Next"
              >
                <.icon name="hero-chevron-right-micro" class="size-4" />
              </.link>
            </div>

            <div id="who-toggle" class="join">
              <.link
                :for={{who, label} <- [everyone: "Everyone", me: "Me"]}
                id={"who-#{who}"}
                patch={chart_path(assigns, who: who)}
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

        <.timeline id="timeline" buckets={@timeline} />

        <div class="grid gap-4 lg:grid-cols-3">
          <.chart_list
            id="top-artists"
            title="Artists"
            icon="hero-user-group-micro"
            rows={@artists}
            all={~p"/artists?#{if(@who == :me, do: [who: :me], else: [])}"}
          >
            <:row :let={row}>
              <.link
                navigate={~p"/artists/#{row.artist.id}"}
                class="truncate font-medium hover:text-primary"
              >
                {row.artist.name}
              </.link>
            </:row>
          </.chart_list>

          <.chart_list
            id="top-albums"
            title="Albums"
            icon="hero-square-3-stack-3d-micro"
            rows={@albums}
            all={~p"/albums?#{if(@who == :me, do: [who: :me], else: [])}"}
          >
            <:row :let={row}>
              <.cover album={row.album} class="size-9" />
              <.link navigate={~p"/albums/#{row.album.id}"} class="min-w-0 hover:text-primary">
                <p class="truncate font-medium">{row.album.title}</p>
                <p class="truncate text-xs text-base-content/60">{row.album.artist.name}</p>
              </.link>
            </:row>
          </.chart_list>

          <.chart_list id="top-tracks" title="Tracks" icon="hero-musical-note-micro" rows={@tracks}>
            <:row :let={row}>
              <div class="min-w-0">
                <.link
                  navigate={~p"/artists/#{row.track.artist.id}"}
                  class="block truncate font-medium hover:text-primary"
                >
                  {row.track.title}
                </.link>
                <.link
                  navigate={~p"/artists/#{row.track.artist.id}"}
                  class="block truncate text-xs text-base-content/60 hover:text-primary"
                >
                  {row.track.artist.name}
                </.link>
              </div>
            </:row>
          </.chart_list>
        </div>

        <div class="grid gap-4 lg:grid-cols-3">
          <section id="now-playing" class="rounded-box border border-base-300 bg-base-200 p-4">
            <h2 class="mb-3 flex items-center gap-2 font-semibold">
              <span class="relative flex size-2">
                <span
                  :if={@now_playing != []}
                  class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-75"
                />
                <span class={[
                  "relative inline-flex size-2 rounded-full",
                  if(@now_playing != [], do: "bg-success", else: "bg-base-content/30")
                ]} />
              </span>
              Listening now
            </h2>
            <p :if={@now_playing == []} class="py-4 text-center text-sm text-base-content/60">
              Nobody right now.
            </p>
            <ul class="space-y-3">
              <li :for={np <- @now_playing} id={"now-#{np.user_id}"} class="flex items-center gap-3">
                <.cover album={np.album} class="size-10" />
                <div class="min-w-0 text-sm">
                  <.link
                    navigate={play_path(np)}
                    class="block truncate font-medium hover:text-primary"
                  >
                    {np.track.title}
                  </.link>
                  <p class="truncate text-xs text-base-content/60">
                    <.link navigate={~p"/artists/#{np.track.artist.id}"} class="hover:text-primary">
                      {np.track.artist.name}
                    </.link>
                    · {FinalTrack.Accounts.User.display_name(np.user)}
                  </p>
                </div>
              </li>
            </ul>
          </section>

          <section
            id="recent-plays"
            class="rounded-box border border-base-300 bg-base-200 p-4 lg:col-span-2"
          >
            <h2 class="mb-3 flex items-center gap-2 font-semibold">
              <.icon name="hero-clock-micro" class="size-4 text-accent" /> Latest plays
            </h2>
            <p :if={@recent == []} class="py-4 text-center text-sm text-base-content/60">
              No plays yet.
              <.link navigate={~p"/users/scrobbling"} class="link link-primary">
                Connect a scrobbler
              </.link>
              to get started.
            </p>
            <ul class="divide-y divide-base-300">
              <li :for={s <- @recent} id={"play-#{s.id}"} class="flex items-center gap-3 py-2">
                <.cover album={s.album} class="size-8" />
                <div class="min-w-0 flex-1 text-sm">
                  <p class="truncate">
                    <.link navigate={play_path(s)} class="font-medium hover:text-primary">
                      {s.track.title}
                    </.link>
                    <span class="text-base-content/60">
                      ·
                      <.link navigate={~p"/artists/#{s.track.artist.id}"} class="hover:text-primary">
                        {s.track.artist.name}
                      </.link>
                    </span>
                  </p>
                </div>
                <span class="hidden shrink-0 text-xs text-base-content/60 sm:inline">
                  {FinalTrack.Accounts.User.display_name(s.user)}
                </span>
                <span class="w-16 shrink-0 text-right font-mono text-xs text-base-content/50">
                  {ago(s.played_at)}
                </span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end

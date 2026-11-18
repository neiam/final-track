defmodule FinalTrackWeb.MusicComponents do
  @moduledoc """
  Pieces shared by the chart, album and artist pages: covers, ranked rows,
  the plays-over-time bars.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: FinalTrackWeb.Endpoint,
    router: FinalTrackWeb.Router,
    statics: FinalTrackWeb.static_paths()

  alias FinalTrack.Catalog.Album

  @doc """
  The URL of an album's cover, or nil. Versioned by the file's key, which
  changes with every new cover, so it can be cached forever.
  """
  def cover_url(%Album{cover_key: nil}), do: nil

  def cover_url(%Album{id: id, cover_key: key}),
    do: ~p"/covers/#{id}?#{[v: key |> Path.basename() |> Path.rootname()]}"

  def cover_url(_), do: nil

  @doc """
  An album cover, or (without one, or without an album) a placeholder tinted
  from the title so a wall of missing covers isn't a wall of grey.
  """
  attr :album, :any, default: nil
  attr :class, :string, default: "size-12"
  attr :rest, :global

  def cover(assigns) do
    assigns = assign(assigns, :url, cover_url(assigns.album))

    ~H"""
    <div
      class={[
        "relative shrink-0 overflow-hidden rounded-box border border-base-300 bg-base-300",
        @class
      ]}
      {@rest}
    >
      <img
        :if={@url}
        src={@url}
        alt={"Cover of #{@album.title}"}
        loading="lazy"
        class="size-full object-cover"
      />
      <div
        :if={!@url}
        class="flex size-full items-center justify-center"
        style={placeholder_style(@album)}
        aria-hidden="true"
      >
        <svg viewBox="0 0 24 24" class="size-2/5 opacity-60" fill="none" stroke="currentColor">
          <circle cx="12" cy="12" r="9" stroke-width="1.5" />
          <circle cx="12" cy="12" r="2.5" stroke-width="1.5" />
        </svg>
      </div>
    </div>
    """
  end

  defp placeholder_style(%Album{title: title}) do
    hue = :erlang.phash2(title, 360)

    "background: linear-gradient(135deg, oklch(45% 0.08 #{hue}), oklch(30% 0.06 #{rem(hue + 40, 360)})); color: oklch(90% 0.03 #{hue});"
  end

  defp placeholder_style(_), do: "color: var(--color-base-content);"

  @doc """
  A numbered chart list. Each row's background bar is its share of the
  leader's plays.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :rows, :list, required: true
  attr :empty, :string, default: "Nothing played yet."
  attr :all, :string, default: nil, doc: "a link to the full list"
  slot :row, required: true

  def chart_list(assigns) do
    assigns = assign(assigns, :max, assigns.rows |> Enum.map(& &1.plays) |> Enum.max(fn -> 1 end))

    ~H"""
    <section id={@id} class="rounded-box border border-base-300 bg-base-200 p-4">
      <h2 class="mb-3 flex items-center gap-2 font-semibold">
        <FinalTrackWeb.CoreComponents.icon name={@icon} class="size-4 text-accent" />
        {@title}
        <.link
          :if={@all}
          navigate={@all}
          class="ml-auto flex items-center gap-0.5 text-xs font-normal text-base-content/60 transition-colors hover:text-primary"
        >
          All <FinalTrackWeb.CoreComponents.icon name="hero-chevron-right-micro" class="size-3" />
        </.link>
      </h2>
      <p :if={@rows == []} class="py-6 text-center text-sm text-base-content/60">{@empty}</p>
      <ol :if={@rows != []} class="space-y-1">
        <li
          :for={{row, i} <- Enum.with_index(@rows, 1)}
          class="group relative flex items-center gap-3 overflow-hidden rounded-field px-2 py-1.5 transition-colors hover:bg-base-300/60"
        >
          <div
            class="absolute inset-y-0 left-0 bg-primary/10 transition-[width] duration-500"
            style={"width: #{round(row.plays / @max * 100)}%"}
            aria-hidden="true"
          />
          <span class="relative w-6 shrink-0 text-right font-mono text-xs text-base-content/60">
            {i}
          </span>
          <div class="relative flex min-w-0 flex-1 items-center gap-3">
            {render_slot(@row, row)}
          </div>
          <span class="relative shrink-0 font-mono text-xs tabular-nums text-base-content/70">
            {row.plays}
          </span>
        </li>
      </ol>
    </section>
    """
  end

  @doc "Plays over a period as bars (see `FinalTrack.Charts.timeline/3`)."
  attr :id, :string, required: true
  attr :buckets, :list, required: true

  def timeline(assigns) do
    assigns =
      assign(assigns, :max, assigns.buckets |> Enum.map(& &1.plays) |> Enum.max(fn -> 0 end))

    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-200 p-4">
      <div class="flex h-32 items-end gap-0.5 sm:gap-1">
        <div
          :for={b <- @buckets}
          class="group relative flex h-full flex-1 flex-col justify-end"
          title={"#{b.label}: #{b.plays} #{if b.plays == 1, do: "play", else: "plays"}"}
        >
          <div
            class={[
              "w-full rounded-t-sm transition-all duration-500",
              if(b.plays > 0,
                do: "bg-primary group-hover:bg-accent",
                else: "bg-base-300"
              )
            ]}
            style={"height: #{if @max > 0 and b.plays > 0, do: max(round(b.plays / @max * 100), 3), else: 2}%"}
          />
        </div>
      </div>
      <div class="mt-1 flex gap-0.5 sm:gap-1">
        <span
          :for={{b, i} <- Enum.with_index(@buckets)}
          class={
            [
              "flex-1 truncate text-center font-mono text-[10px] text-base-content/50",
              # Thin out labels when there are many bars.
              (length(@buckets) > 12 and rem(i, label_every(length(@buckets))) != 0) && "invisible"
            ]
          }
        >
          {b.label}
        </span>
      </div>
    </div>
    """
  end

  defp label_every(n) when n > 24, do: 5
  defp label_every(_), do: 3

  @doc """
  The "keep my plays of this private" switch for an artist or album page.
  `inherited?` says it's already private through something above it (an
  album whose artist is private), which the switch can't undo.
  """
  attr :id, :string, required: true
  attr :private?, :boolean, required: true
  attr :inherited?, :boolean, default: false
  attr :event, :string, required: true
  attr :what, :string, required: true

  def private_toggle(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <button
        id={@id}
        type="button"
        phx-click={@event}
        aria-pressed={to_string(@private?)}
        class={[
          "btn btn-sm gap-2 transition",
          if(@private?, do: "btn-warning", else: "btn-ghost border border-base-300")
        ]}
      >
        <FinalTrackWeb.CoreComponents.icon
          name={if @private?, do: "hero-lock-closed-micro", else: "hero-lock-open-micro"}
          class="size-4"
        />
        {if @private?, do: "Private", else: "Shared"}
      </button>
      <span class="text-xs text-base-content/60">
        <%= cond do %>
          <% @private? -> %>
            Only you see your plays of this {@what}.
          <% @inherited? -> %>
            Already private: you keep its artist private.
          <% true -> %>
            Others see your plays of this {@what}.
        <% end %>
      </span>
    </div>
    """
  end

  @doc "\"1 play\" / \"12 plays\"."
  def plays(1), do: "1 play"
  def plays(n), do: "#{n} plays"

  @doc "A compact relative time: \"just now\", \"5m ago\", \"3h ago\", else a date."
  def ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> Calendar.strftime(at, "%-d %b %Y")
    end
  end
end

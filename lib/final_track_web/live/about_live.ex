defmodule FinalTrackWeb.AboutLive do
  @moduledoc """
  `/about`: what Final Track is, who sees what, how to join, and — as
  angler's about page — how to run your own: pick a container runtime, type
  the blanks into the command, copy.
  """
  use FinalTrackWeb, :live_view

  # {key, label, binary}: container runtimes for "Run your own".
  @runtimes [{:podman, "Podman", "podman"}, {:docker, "Docker", "docker"}]

  # {key, label, image}: the public registries the image is published to
  # (.github/workflows/ci.yml). The forge's own registry is private.
  @registries [
    {:ghcr, "GitHub", "ghcr.io/neiam/final-track"},
    {:dockerhub, "Docker Hub", "docker.io/neiam/final-track"},
    {:quay, "Quay", "quay.io/neiam/final-track"}
  ]

  # {name, placeholder (and default), width class, label}: the blanks.
  @config_fields [
    {"user", "USER", "w-24", "Database user"},
    {"password", "PASS", "w-24", "Database password"},
    {"host", "tracks.you.com", "w-40", "Public host"}
  ]

  @optional_settings [
    {"SMTP_RELAY, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, MAIL_FROM_ADDRESS",
     "Send mail (emailed log-in links, confirmations). Without it, mail is off and registration takes a password."},
    {"OIDC_ENABLED, OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET",
     "Sign in through your OpenID Connect provider. The redirect URI is https://HOST/auth/oidc/neiam/callback."},
    {"FINAL_TRACK_ACTIVITYPUB=true",
     "Let members give their plays a fediverse account. Set PHX_HOST to its final domain first."},
    {"FINAL_TRACK_MUSICBRAINZ_USER_AGENT",
     "How the server introduces itself to MusicBrainz for cover lookups: include a URL or address to reach you."},
    {"FINAL_TRACK_AUTO_FETCH_COVERS=false",
     "Only fetch covers when someone asks on the album page."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "About")
     |> assign(:runtimes, @runtimes)
     |> assign(:registries, @registries)
     |> assign(:config_fields, @config_fields)
     |> assign(:optional_settings, @optional_settings)
     |> assign(:runtime, :podman)
     |> assign(:registry, :ghcr)
     |> assign(:config_form, to_form(%{"user" => "", "password" => "", "host" => ""}))
     |> recompute_commands()}
  end

  @impl true
  def handle_event("set_runtime", %{"runtime" => runtime}, socket),
    do:
      {:noreply,
       socket |> assign(:runtime, pick(@runtimes, runtime, :podman)) |> recompute_commands()}

  def handle_event("set_registry", %{"registry" => registry}, socket),
    do:
      {:noreply,
       socket |> assign(:registry, pick(@registries, registry, :ghcr)) |> recompute_commands()}

  def handle_event("set_config", params, socket) do
    form = to_form(Map.take(params, ["user", "password", "host"]))
    {:noreply, socket |> assign(:config_form, form) |> recompute_commands()}
  end

  # The key named by a param, from a fixed list: never String.to_atom on input.
  defp pick(rows, value, default) do
    Enum.find_value(rows, default, fn {key, _, _} -> if Atom.to_string(key) == value, do: key end)
  end

  defp recompute_commands(socket) do
    %{runtime: runtime, registry: registry, config_form: form} = socket.assigns
    bin = lookup(@runtimes, runtime)
    image = lookup(@registries, registry)
    user = blank(form, "user", "USER")
    pass = blank(form, "password", "PASS")
    host = blank(form, "host", "tracks.you.com")

    socket
    |> assign(:db_command, db_command(bin, user, pass))
    |> assign(:run_command, run_command(bin, image, user, pass, host))
    |> assign(:setup_command, setup_command(bin))
  end

  defp db_command(bin, user, pass) do
    "#{bin} network create final-track\n\n" <>
      lines([
        "#{bin} run -d --name final-track-db --network final-track",
        "-e POSTGRES_USER=#{user}",
        "-e POSTGRES_PASSWORD=#{pass}",
        "-e POSTGRES_DB=final_track",
        "-v final-track-db:/var/lib/postgresql/data",
        "docker.io/postgres:17-alpine"
      ])
  end

  defp run_command(bin, image, user, pass, host) do
    lines([
      "#{bin} run -d --name final-track --network final-track",
      "-p 4000:4000",
      "-e PHX_HOST=#{host}",
      "-e SECRET_KEY_BASE=$(openssl rand -base64 48)",
      "-e DATABASE_URL=ecto://#{user}:#{pass}@final-track-db/final_track",
      "-v final-track-covers:/var/lib/final_track/covers",
      "#{image}:latest"
    ])
  end

  defp setup_command(bin) do
    "#{bin} exec final-track bin/migrate\n#{bin} exec final-track bin/invite --note \"first\""
  end

  defp lines(parts), do: Enum.join(parts, " \\\n  ")

  defp blank(form, key, default) do
    case form[key].value |> to_string() |> String.trim() do
      "" -> default
      value -> value
    end
  end

  defp lookup(rows, key) do
    {_key, _label, value} = Enum.find(rows, fn {k, _, _} -> k == key end)
    value
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  defp command(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        id={"copy-#{@id}"}
        phx-hook=".CopyCommand"
        data-target={@id}
        class="btn btn-ghost btn-xs absolute right-2 top-2 gap-1"
        aria-label="Copy command"
      >
        <.icon name="hero-clipboard-document-micro" class="size-4" />
        <span data-label>Copy</span>
      </button>
      <pre
        id={@id}
        class="overflow-x-auto rounded-box bg-base-300 p-4 pt-9 font-mono text-xs leading-relaxed sm:text-sm"
      ><code>{@text}</code></pre>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyCommand">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const pre = document.getElementById(this.el.dataset.target)
              const label = this.el.querySelector("[data-label]")
              if (!pre) return
              try {
                await navigator.clipboard.writeText(pre.textContent.trim())
                if (label) {
                  label.textContent = "Copied!"
                  setTimeout(() => { label.textContent = "Copy" }, 1500)
                }
              } catch (_e) {
                // No clipboard API on plain http: select the text instead.
                const range = document.createRange()
                range.selectNodeContents(pre)
                const sel = window.getSelection()
                sel.removeAllRanges()
                sel.addRange(range)
              }
            })
          }
        }
      </script>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8">
        <section id="hero" class="py-20 sm:py-28 text-center">
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent mb-4">Final Track</p>
          <h1 class="text-4xl sm:text-6xl font-bold tracking-tight">
            What you've been playing, together.
          </h1>
          <p class="text-base-content/70 text-lg sm:text-xl mt-6 max-w-2xl mx-auto leading-relaxed">
            A self-hosted scrobble server for you and your people. Point Scropple at it, watch the
            plays roll in live, and see the artists, albums and tracks that ruled the day, the week,
            the month or the year.
          </p>
          <div class="flex flex-wrap justify-center gap-3 mt-8">
            <%= cond do %>
              <% @current_scope && @current_scope.user -> %>
                <.link navigate={~p"/charts"} class="btn btn-primary" id="hero-cta">
                  <.icon name="hero-chart-bar-micro" class="size-4" /> Open charts
                </.link>
                <.link navigate={~p"/artists"} class="btn btn-ghost">Library</.link>
                <.link navigate={~p"/users/scrobbling"} class="btn btn-ghost">Connect a scrobbler</.link>
              <% FinalTrack.Accounts.registration_open?() and NeiamAuth.local_login_enabled?() -> %>
                <.link navigate={~p"/users/register"} class="btn btn-primary" id="hero-cta">
                  Get started
                </.link>
                <.link navigate={~p"/users/log-in"} class="btn btn-ghost">Log in</.link>
                <.link navigate={~p"/"} class="btn btn-ghost" id="hero-live">
                  See what's playing
                </.link>
              <% true -> %>
                <span class="btn btn-disabled" id="hero-cta" title="Registration is invite-only">
                  Get started · invite-only
                </span>
                <.link navigate={~p"/users/log-in"} class="btn btn-ghost">Log in</.link>
                <.link navigate={~p"/"} class="btn btn-ghost" id="hero-live">
                  See what's playing
                </.link>
            <% end %>
          </div>
        </section>

        <section id="features" class="py-12 sm:py-16">
          <h2 class="text-2xl sm:text-3xl font-bold mb-2">What you get</h2>
          <p class="text-base-content/70 mb-8">
            Your listening history, on your own server, shared only as far as you like.
          </p>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <div
              :for={
                {id, icon, title, body} <-
                  [
                    {"live", "hero-squares-2x2-micro", "Live on the front page",
                     "The latest plays as a wall of album art, updating as they land. Visitors see what was played; members see who played it."},
                    {"charts", "hero-chart-bar-micro", "Charts by day, week, month, year",
                     "Top artists, albums and tracks for any period, plays over time in your own time zone, and who's listening right now. Everyone's, or just yours."},
                    {"library", "hero-rectangle-stack-micro", "A library with numbers",
                     "Every artist and album that's been played, with plays, listeners, tracks and when it was first and last heard. Sort it, search it."},
                    {"covers", "hero-photo-micro", "Covers, found or yours",
                     "Album art is looked up on MusicBrainz and the Cover Art Archive the first time an album is played. Got a better scan? Drop it on the album."},
                    {"private", "hero-lock-closed-micro", "Private when you want",
                     "Mark an artist, album or track private and your plays of it are only ever shown to you, including ones from before you marked it."},
                    {"scropple", "hero-signal-micro", "Speaks Scropple",
                     "The same HTTP API as ircd's ScrobbleServ, so one phone can scrobble here, to an IRC channel and to Last.fm at once. One token per device."}
                  ] ++
                    if(FinalTrack.Federation.enabled?(),
                      do: [
                        {"fediverse", "hero-globe-alt-micro", "On the fediverse, if you like",
                         "Give your plays an account Mastodon users can follow. Each play is posted with its album cover; private ones never are, and marking something private withdraws what was posted."}
                      ],
                      else: []
                    ) ++
                    if(NeiamAuth.enabled?() and NeiamAuth.providers() != [],
                      do: [
                        {"sso", "hero-key-micro", "OpenID Connect",
                         "Sign in through this server's identity provider (Authelia, Keycloak, Google and the like) instead of keeping another password."}
                      ],
                      else: []
                    )
              }
              id={"feature-#{id}"}
              class="rounded-box border border-base-300 bg-base-200 p-5 transition duration-200 hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md"
            >
              <div class="flex items-center gap-2 mb-2">
                <.icon name={icon} class="size-5 text-accent" />
                <h3 class="font-semibold">{title}</h3>
              </div>
              <p class="text-sm text-base-content/80">{body}</p>
            </div>
          </div>
        </section>

        <section id="who-sees-what" class="py-12 sm:py-16">
          <h2 class="text-2xl sm:text-3xl font-bold mb-2">Who sees what</h2>
          <p class="text-base-content/70 mb-8">
            Plays are only ever as public as the narrowest thing about them.
          </p>

          <dl class="divide-y divide-base-300 overflow-hidden rounded-box border border-base-300 bg-base-200">
            <div
              :for={
                {who, icon, sees} <-
                  [
                    {"Anyone", "hero-eye-micro",
                     "The front page: what was played and when. Never who played it, and nothing anyone keeps private."},
                    {"Members", "hero-user-group-micro",
                     "Charts, the library, album and artist pages, and who played what. Not your private plays."}
                  ] ++
                    if(FinalTrack.Federation.enabled?(),
                      do: [
                        {"Your followers", "hero-globe-alt-micro",
                         "If you turn on a fediverse account: each of your plays that isn't private, as it happens."}
                      ],
                      else: []
                    ) ++
                    [
                      {"You", "hero-user-circle-micro",
                       "Everything you've played, private or not, in every chart and list."}
                    ]
              }
              class="grid gap-1 px-5 py-4 sm:grid-cols-[10rem_1fr] sm:gap-4"
            >
              <dt class="flex items-center gap-2 font-semibold">
                <.icon name={icon} class="size-4 text-accent" />
                {who}
              </dt>
              <dd class="text-sm text-base-content/80">{sees}</dd>
            </div>
          </dl>
        </section>

        <section id="steps" class="py-12 sm:py-16">
          <h2 class="text-2xl sm:text-3xl font-bold mb-2">Get started in three steps</h2>
          <p class="text-base-content/70 mb-8">
            From invite link to your first chart in a few minutes.
          </p>

          <ol class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <li
              :for={
                {n, title, body} <- [
                  {"01", "Accept your invite",
                   "Final Track is invite-only: open the link a member gave you, or sign in through the server's OpenID Connect provider if you have an account there."},
                  {"02", "Make a token",
                   "On the Scrobbling page, make one per device. It's shown once; copy it."},
                  {"03", "Point Scropple here",
                   "In Scropple, add an HTTP backend with this server's address and your token. Then just listen."}
                ]
              }
              class="border border-base-300 rounded-box p-5 bg-base-200 flex flex-col gap-2"
            >
              <span class="font-mono text-xs text-accent">{n}</span>
              <h3 class="font-semibold">{title}</h3>
              <p class="text-sm text-base-content/80">{body}</p>
            </li>
          </ol>
        </section>

        <section id="run-your-own" class="py-12 sm:py-16 space-y-4">
          <div>
            <h2 class="text-2xl sm:text-3xl font-bold mb-2">Run your own</h2>
            <p class="text-base-content/70">
              <span class="font-medium text-base-content">Get started in a minute.</span>
              Final Track ships as a single container image next to a PostgreSQL. Pick your runtime,
              fill in the blanks, then run:
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <div role="tablist" class="join" aria-label="Container runtime" id="run-runtimes">
              <button
                :for={{key, label, _bin} <- @runtimes}
                type="button"
                role="tab"
                id={"runtime-#{key}"}
                phx-click="set_runtime"
                phx-value-runtime={key}
                aria-selected={to_string(@runtime == key)}
                class={[
                  "btn btn-sm join-item",
                  if(@runtime == key, do: "btn-primary", else: "btn-ghost")
                ]}
              >
                {label}
              </button>
            </div>
            <div :if={length(@registries) > 1} role="tablist" class="join" aria-label="Registry">
              <button
                :for={{key, label, _image} <- @registries}
                type="button"
                role="tab"
                id={"registry-#{key}"}
                phx-click="set_registry"
                phx-value-registry={key}
                aria-selected={to_string(@registry == key)}
                class={[
                  "btn btn-sm join-item",
                  if(@registry == key, do: "btn-secondary", else: "btn-ghost")
                ]}
              >
                {label}
              </button>
            </div>
          </div>

          <.form
            for={@config_form}
            id="run-config"
            phx-change="set_config"
            class="flex flex-wrap items-center gap-x-4 gap-y-1 font-mono text-sm"
          >
            <label
              :for={{name, placeholder, width, aria} <- @config_fields}
              class="flex items-center gap-1.5"
            >
              <span class="text-base-content/40">{name}</span>
              <input
                type="text"
                name={name}
                value={@config_form[name].value}
                placeholder={placeholder}
                autocomplete="off"
                spellcheck="false"
                phx-debounce="150"
                aria-label={aria}
                class={["input input-ghost input-xs px-1", width]}
              />
            </label>
          </.form>

          <div class="collapse collapse-arrow rounded-box border border-base-300 bg-base-200">
            <input type="checkbox" aria-label="Toggle database setup" />
            <div class="collapse-title text-sm font-medium">First: start your database</div>
            <div class="collapse-content space-y-2">
              <p class="text-xs text-base-content/60">
                A network for the two containers, and PostgreSQL on it. The app finds it by name.
              </p>
              <.command id="db-command" text={@db_command} />
            </div>
          </div>

          <.command id="run-command" text={@run_command} />

          <div class="space-y-2 text-sm text-base-content/70">
            <p>Then migrate the database and make the first invite (registration is invite-only):</p>
            <.command id="setup-command" text={@setup_command} />
          </div>

          <details class="rounded-box border border-base-300 bg-base-200 p-4 text-sm">
            <summary class="cursor-pointer font-medium">Optional settings</summary>
            <dl class="mt-3 space-y-2">
              <div
                :for={{vars, what} <- @optional_settings}
                class="grid gap-1 sm:grid-cols-[18rem_1fr]"
              >
                <dt class="font-mono text-xs text-base-content/80">{vars}</dt>
                <dd class="text-base-content/70">{what}</dd>
              </div>
            </dl>
          </details>

          <p class="text-xs text-base-content/50">
            The server listens on port 4000; put a TLS-terminating proxy in front of it. Album covers
            live in the <code class="text-base-content/70">final-track-covers</code>
            volume. Clustered and Kubernetes setups are in the repo's deployment notes.
          </p>
        </section>

        <footer id="footer" class="py-10 sm:py-12 mt-8 border-t border-base-300 text-center">
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-base-content/70 flex items-center justify-center gap-2">
            <span class="font-bold tracking-[0.16em]">FINAL TRACK</span>
            <span class="opacity-50">·</span>
            <span>a</span>
            <%!--
              Hardcoded oklch from the neiam-co accent (the value every ported
              theme assigns to --color-accent), so the NEIAM mark stays yellow
              whichever theme the viewer has picked.
            --%>
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
end

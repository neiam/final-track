defmodule FinalTrackWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FinalTrackWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  The chrome (navbar, theme picker, brand mark) matches clayman, diogramos
  and pin_flip so the apps read as one family.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "when true, the inner block manages its own width and padding"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300 bg-base-200">
      <div class="flex-1">
        <.link navigate={~p"/"} class="flex w-fit items-center gap-2" id="brand">
          <span class="font-mono font-bold tracking-[0.16em] text-accent">FINAL TRACK</span>
        </.link>
      </div>
      <div class="flex-none">
        <ul class="flex flex-row items-center gap-1">
          <%= if @current_scope && @current_scope.user do %>
            <li>
              <.link id="nav-charts" navigate={~p"/charts"} class="btn btn-ghost btn-sm">
                <.icon name="hero-chart-bar-micro" class="size-4" />
                <span class="hidden sm:inline">Charts</span>
              </.link>
            </li>
            <li>
              <.link id="nav-library" navigate={~p"/artists"} class="btn btn-ghost btn-sm">
                <.icon name="hero-rectangle-stack-micro" class="size-4" />
                <span class="hidden sm:inline">Library</span>
              </.link>
            </li>
            <li>
              <.link id="nav-scrobbling" navigate={~p"/users/scrobbling"} class="btn btn-ghost btn-sm">
                <.icon name="hero-signal-micro" class="size-4" />
                <span class="hidden sm:inline">Scrobbling</span>
              </.link>
            </li>
            <li>
              <.link id="nav-invites" navigate={~p"/users/invites"} class="btn btn-ghost btn-sm">
                <.icon name="hero-envelope-micro" class="size-4" />
                <span class="hidden sm:inline">Invites</span>
              </.link>
            </li>
            <li><span class="divider divider-horizontal mx-0" /></li>
            <li>
              <.theme_toggle />
            </li>
            <li>
              <details id="user-menu" class="dropdown dropdown-end">
                <summary class="btn btn-ghost btn-sm">
                  <.icon name="hero-user-circle-micro" class="size-4" />
                  <span class="hidden sm:inline truncate max-w-[12ch]">
                    {FinalTrack.Accounts.User.display_name(@current_scope.user)}
                  </span>
                </summary>
                <ul class="dropdown-content menu bg-base-200 border border-base-300 rounded-box z-10 mt-1 w-48 p-1 shadow-lg">
                  <li class="menu-title font-mono text-xs truncate">
                    {@current_scope.user.email}
                  </li>
                  <li>
                    <.link navigate={~p"/users/settings"} id="nav-settings">
                      <.icon name="hero-cog-6-tooth-micro" class="size-4" /> Settings
                    </.link>
                  </li>
                  <li>
                    <.link href={~p"/users/log-out"} method="delete" id="nav-log-out">
                      <.icon name="hero-arrow-right-on-rectangle-micro" class="size-4" /> Log out
                    </.link>
                  </li>
                </ul>
              </details>
            </li>
          <% else %>
            <li>
              <.theme_toggle />
            </li>
            <li>
              <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm" id="nav-log-in">
                Log in
              </.link>
            </li>
            <li :if={NeiamAuth.local_login_enabled?()}>
              <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm" id="nav-register">
                Register
              </.link>
            </li>
          <% end %>
        </ul>
      </div>
    </header>

    <%= if @wide do %>
      <main class="w-full">
        {render_slot(@inner_block)}
      </main>
    <% else %>
      <main class="px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-5xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Theme picker dropdown listing every theme in `FinalTrack.Themes`. The
  selected theme is persisted to localStorage by the script in
  `root.html.heex`, which also handles the `phx:set-theme` event dispatched
  here.
  """
  def theme_toggle(assigns) do
    assigns = assign_new(assigns, :themes, fn -> FinalTrack.Themes.all() end)

    ~H"""
    <div class="dropdown dropdown-end">
      <div
        id="theme-toggle"
        tabindex="0"
        role="button"
        class="btn btn-ghost btn-sm gap-2"
        aria-label="Choose theme"
      >
        <.icon name="hero-swatch-micro" class="size-4" />
        <span class="hidden sm:inline">Theme</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-200 border border-base-300 rounded-box z-10 mt-1 w-44 p-1 shadow-lg"
      >
        <li>
          <button
            type="button"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme="system"
            class="flex items-center gap-2"
          >
            <.icon name="hero-computer-desktop-micro" class="size-4" /> System
          </button>
        </li>
        <li :for={theme <- @themes}>
          <button
            type="button"
            phx-click={JS.dispatch("phx:set-theme")}
            data-phx-theme={theme}
            class="flex items-center justify-between"
          >
            <span class="capitalize">{theme}</span>
            <span
              class="size-3 rounded-full border border-base-content/20"
              data-theme={theme}
              style="background: var(--color-primary)"
            />
          </button>
        </li>
      </ul>
    </div>
    """
  end
end

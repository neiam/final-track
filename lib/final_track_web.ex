defmodule FinalTrackWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use FinalTrackWeb, :controller
      use FinalTrackWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: FinalTrackWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: FinalTrackWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import FinalTrackWeb.CoreComponents
      # Covers, chart rows, timelines
      import FinalTrackWeb.MusicComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias FinalTrackWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FinalTrackWeb.Endpoint,
        router: FinalTrackWeb.Router,
        statics: FinalTrackWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  @doc """
  The registration link for an invite, on the endpoint's configured URL.
  Only an invite fresh from being created or rotated has one: just the
  token's hash is stored.
  """
  def invite_url(%FinalTrack.Accounts.Invite{token: token}) when is_binary(token) do
    base_url() <> "/users/register?" <> URI.encode_query(invite: token)
  end

  @doc """
  The endpoint's public URL. Works without the endpoint running (a
  release's `eval`, where `Endpoint.url/0` raises) by reading its config.
  """
  def base_url do
    if Process.whereis(FinalTrackWeb.Endpoint) do
      FinalTrackWeb.Endpoint.url()
    else
      config = Application.get_env(:final_track, FinalTrackWeb.Endpoint, [])
      url = Keyword.get(config, :url, [])
      scheme = Keyword.get(url, :scheme, "http")
      host = Keyword.get(url, :host, "localhost")

      port =
        Keyword.get_lazy(url, :port, fn -> get_in(config, [:http, :port]) || 80 end)

      default? = {scheme, port} in [{"http", 80}, {"https", 443}]
      "#{scheme}://#{host}" <> if(default?, do: "", else: ":#{port}")
    end
  end
end

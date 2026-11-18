defmodule FinalTrackWeb.Router do
  use FinalTrackWeb, :router

  import FinalTrackWeb.UserAuth
  import NeiamAuth.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FinalTrackWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Scrobbling clients (Scropple's HTTP backend): JSON, authenticated by a
  # per-device bearer token rather than a session, so no CSRF.
  pipeline :scrobble_api do
    plug :accepts, ["json"]
    plug FinalTrackWeb.Plugs.ScrobbleAuth
  end

  scope "/", FinalTrackWeb do
    pipe_through :browser

    get "/about", PageController, :about
    # Album art isn't private (plays are), and the landing grid shows it to
    # signed-out visitors too.
    get "/covers/:id", CoverController, :show
  end

  # ActivityPub. No :accepts (fediverse servers' Accept headers vary), no
  # session or CSRF (requests are verified by HTTP signature), and 404
  # throughout while federation is off.
  pipeline :federation do
    plug FinalTrackWeb.Plugs.RequireFederation
  end

  # `/@username`: what browsers and fediverse servers both ask for, so no
  # :accepts (an activity+json request would be a 406), but the session
  # and layout, for the profile page. 404 while federation is off.
  pipeline :profile do
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FinalTrackWeb.Layouts, :root}
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug FinalTrackWeb.Plugs.RequireFederation
  end

  scope "/", FinalTrackWeb do
    pipe_through :profile

    get "/@:username", ProfileController, :show
  end

  scope "/", FinalTrackWeb do
    pipe_through :federation

    get "/.well-known/webfinger", FederationController, :webfinger
    get "/.well-known/host-meta", FederationController, :host_meta
    get "/.well-known/nodeinfo", FederationController, :nodeinfo_links
    get "/nodeinfo/2.0", FederationController, :nodeinfo

    get "/ap/actor", FederationController, :instance_actor
    post "/ap/actor/inbox", FederationController, :inbox
    post "/ap/inbox", FederationController, :inbox
    get "/ap/users/:username", FederationController, :actor
    get "/ap/users/:username/outbox", FederationController, :outbox
    get "/ap/users/:username/followers", FederationController, :followers
    post "/ap/users/:username/inbox", FederationController, :user_inbox
    get "/ap/notes/:id", FederationController, :note
  end

  scope "/api/v1", FinalTrackWeb.Api do
    pipe_through :scrobble_api

    post "/now-playing", ScrobbleController, :now_playing
    post "/scrobble", ScrobbleController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:final_track, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FinalTrackWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", FinalTrackWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{FinalTrackWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/invites", UserLive.Invites, :index
      live "/users/scrobbling", UserLive.Scrobbling, :index

      # Listening history is for members (the server is invite-only).
      live "/charts", ChartsLive, :index
      live "/artists", LibraryLive, :artists
      live "/albums", LibraryLive, :albums
      live "/albums/:id", AlbumLive.Show, :show
      live "/artists/:id", ArtistLive.Show, :show
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", FinalTrackWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{FinalTrackWeb.UserAuth, :mount_current_scope}] do
      # The landing grid: public, with more for members.
      live "/", HomeLive, :index
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    # Signed out, from an invite addressed to an email: create that account
    # (confirmed) and sign in. A controller so it can set the session; the
    # registration page posts here with phx-trigger-action.
    post "/users/register/invite", InviteController, :register

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete

    # Sign in with NEIAM (OIDC): GET /auth/oidc/:provider/{login,callback} and
    # /auth/oidc/health. In :browser because the flow state rides in the
    # session cookie; both are GETs, so CSRF doesn't apply. 404 while
    # OIDC_ENABLED is off.
    neiam_auth_routes()

    # OIDC_LOGIN_MODE=sso_strict: an addressed invite is accepted by signing
    # in with NEIAM first (InviteController.sso/2).
    get "/users/register/invite/sso", InviteController, :sso
  end
end

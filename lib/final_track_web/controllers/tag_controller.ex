defmodule FinalTrackWeb.TagController do
  @moduledoc """
  `/tags/:tag`: what this server has published under a hashtag — where the
  hashtag links in posts point (`#scropple`, `#pinkfloyd`). Public; only
  public accounts' posts and never private plays
  (`FinalTrack.Federation.tagged_posts/2`). 404 while federation is off,
  like the rest of the fediverse side.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.Federation
  alias FinalTrack.Federation.Objects

  def show(conn, %{"tag" => tag}) do
    tag = tag |> String.trim_leading("#") |> String.downcase()

    conn
    |> put_format("html")
    |> assign(:page_title, "#" <> tag)
    |> render(:show, tag: tag, domain: Objects.domain(), posts: Federation.tagged_posts(tag))
  end
end

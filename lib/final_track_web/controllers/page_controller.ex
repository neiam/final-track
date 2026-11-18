defmodule FinalTrackWeb.PageController do
  use FinalTrackWeb, :controller

  def about(conn, _params) do
    render(conn, :about, page_title: "About")
  end
end

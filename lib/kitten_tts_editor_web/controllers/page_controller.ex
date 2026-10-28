defmodule KittenTtsEditorWeb.PageController do
  use KittenTtsEditorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

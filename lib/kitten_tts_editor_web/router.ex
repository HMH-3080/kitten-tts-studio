defmodule KittenTtsEditorWeb.Router do
  use KittenTtsEditorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KittenTtsEditorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KittenTtsEditorWeb do
    pipe_through :browser

    live "/", EditorLive, :index
    live "/editor", EditorLive, :index
  end
end

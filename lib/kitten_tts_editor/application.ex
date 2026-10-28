defmodule KittenTtsEditor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KittenTtsEditorWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:kitten_tts_editor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KittenTtsEditor.PubSub},
      {Task.Supervisor, name: KittenTtsEditor.TaskSupervisor},
      KittenTtsEditor.TTS.Worker,
      KittenTtsEditorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: KittenTtsEditor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KittenTtsEditorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

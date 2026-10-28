defmodule KittenTtsEditor.Repo do
  use Ecto.Repo,
    otp_app: :kitten_tts_editor,
    adapter: Ecto.Adapters.Postgres
end

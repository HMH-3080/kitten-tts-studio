import Config

config :kitten_tts_editor, KittenTtsEditor.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kitten_tts_editor_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :kitten_tts_editor, KittenTtsEditorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "ZADm0oWA9qBTgUICf2V3o9wHCcII7vy/9khvzjwpXzXv+5jz68fj7IYPUoX8Qk/q",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:kitten_tts_editor, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:kitten_tts_editor, ~w(--watch)]}
  ]

config :kitten_tts_editor, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

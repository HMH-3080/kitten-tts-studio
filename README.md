# KittenTTS Studio

KittenTTS Studio is a Phoenix LiveView application for turning text into
downloadable speech. Its interface is in English and its default speech engine
is the lightweight KittenTTS Mini ONNX model, which runs on CPU.

## Features

- Generate speech and preview or download the resulting WAV file.
- Select from the eight voices bundled with KittenTTS Mini: Bella, Jasper, Luna,
  Bruno, Rosie, Hugo, Kiki, and Leo.
- See model readiness, generation progress, and useful error messages.
- Keep the model loaded in a long-lived Python worker between requests.
- Use a responsive, English-language interface.

## Model and limitations

The default model is `KittenML/kitten-tts-mini-0.8`. Its model file is
approximately 80 MB and is downloaded from Hugging Face when the model is first
loaded. The downloaded files are cached by Hugging Face for subsequent runs.

KittenTTS Mini is an English-only model. Arabic text is rejected before
synthesis. Mini provides fixed voices, but not voice cloning or KittenTTS 2's
multilingual and expression-control features. The editor currently exposes the
voice selector and does not expose a speech-speed control.

## Requirements

- Elixir `~> 1.17` and Erlang/OTP compatible with the installed Elixir release.
- PostgreSQL running locally for setup and tests.
- Python 3.10 or later with `pip`.
- Internet access for the initial `kittenml` and model downloads.

The Phoenix asset tools download and run their pinned Tailwind CSS and esbuild
binaries through Mix; a separate Node.js or npm installation is not required.

## Local development

### 1. Configure PostgreSQL

The development and test configurations default to a local PostgreSQL server
using username `postgres` and password `postgres`. If your local credentials or
host differ, update the Repo settings in `config/dev.exs` and `config/test.exs`
before running setup.

### 2. Install KittenTTS

Create a Python virtual environment and install the KittenTTS package:

```sh
python3 -m venv "$HOME/kitten-tts"
"$HOME/kitten-tts/bin/python" -m pip install --upgrade pip
"$HOME/kitten-tts/bin/python" -m pip install kittenml
```

By default, the application searches for
`$HOME/kitten-tts/bin/python`, then `python3` or `python` on `PATH`. To use a
different environment, set `KITTEN_TTS_PYTHON` to its Python executable:

```sh
export KITTEN_TTS_PYTHON="/path/to/venv/bin/python"
```

### 3. Set up and start the application

From the project directory:

```sh
mix setup
mix phx.server
```

`mix setup` installs the Mix dependencies, creates and migrates the development
database, runs the seed script, and builds the frontend assets. Open
[http://localhost:4000](http://localhost:4000) after the server starts.

The first synthesis downloads and initializes the model. The worker reports
readiness in the editor and keeps the model in memory for later requests.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `KITTEN_TTS_PYTHON` | `$HOME/kitten-tts/bin/python`, then `python3` or `python` on `PATH` | Python executable with `kittenml` installed. |
| `KITTEN_TTS_MODEL` | `KittenML/kitten-tts-mini-0.8` | Hugging Face model repository loaded by the worker. |
| `KITTEN_TTS_WEIGHTS` | `emb4` | Weight variant passed to KittenTTS 2 models. KittenTTS Mini does not use this setting. |
| `HF_HOME` | Hugging Face default cache location | Optional Hugging Face cache root. Set it before starting the application to relocate downloaded model files. |
| `PORT` | `4000` | HTTP port used by Phoenix. |

The Mini model is the supported application configuration. Changing
`KITTEN_TTS_MODEL` to another model may require different UI behavior and has
not been validated as an editor configuration.

## How synthesis works

1. The LiveView validates the text and selected voice.
2. The Phoenix worker queues synthesis requests and sends them to the Python
   worker over a line-delimited JSON protocol.
3. The Python process loads `kittenml` and the selected model on the first
   request, then remains alive to serve later requests.
4. The generated WAV is written under `priv/static/audio/` and served from the
   corresponding `/audio/...` URL.

Generated audio is stored on disk and is not automatically deleted by the
application. Include `priv/static/audio/` in your storage and cleanup policy.

## Useful commands

```sh
mix format
mix compile --warnings-as-errors
mix assets.build
mix test
mix precommit
```

`mix test` and `mix precommit` create/use the test database, so PostgreSQL must
be running and reachable with the test credentials. To build production assets:

```sh
MIX_ENV=prod mix assets.deploy
```

## Production configuration

Before starting a production release, configure:

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | PostgreSQL connection URL. |
| `SECRET_KEY_BASE` | Secret used to sign and encrypt session data. Generate one with `mix phx.gen.secret`. |
| `PHX_HOST` | Public hostname used to construct the HTTPS URL. |
| `PORT` | HTTP listener port; defaults to `4000`. |
| `PHX_SERVER` | Set to `true` when starting the release web server. |
| `POOL_SIZE` | Optional database connection pool size; defaults to `10`. |
| `KITTEN_TTS_PYTHON` | Python executable in the production environment with `kittenml` installed. |
| `HF_HOME` | Optional persistent directory for the Hugging Face model cache. |

The runtime also needs network access to Hugging Face on the first model load,
a writable model cache, and a writable audio output directory. Generated audio
is stored inside the application's `priv/static/audio/` directory, so ensure
that location is writable and persistent for your deployment. Do not use the
development PostgreSQL credentials in production.

Build a release after setting the production environment:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Start the release with the runtime variables exported:

```sh
PHX_SERVER=true _build/prod/rel/kitten_tts_editor/bin/kitten_tts_editor start
```

## Troubleshooting

- **Python or `kittenml` cannot be found:** Set `KITTEN_TTS_PYTHON` to the exact
  executable path and verify that importing `kittenml` works with it.
- **The model does not become ready:** Check the application logs, network
  access to Hugging Face, available disk space, and write permissions for the
  model cache.
- **The first request takes longer:** The first request downloads and initializes
  the model. Later requests reuse the running worker and cached model.
- **Arabic input is rejected:** This is expected for KittenTTS Mini; use English
  text with the current model.
- **Database connection is refused:** Start PostgreSQL and confirm the host,
  database, username, and password in the environment-specific config.
- **The audio file cannot be played or downloaded:** Check that the generated
  file exists under `priv/static/audio/` and that the application can serve
  files from that directory.

## Project layout

| Path | Purpose |
| --- | --- |
| `lib/kitten_tts_editor/tts/worker.ex` | Phoenix-side queue, backend selection, and synthesis results. |
| `priv/python/tts_worker.py` | Long-lived Python process and KittenTTS API integration. |
| `lib/kitten_tts_editor_web/live/editor_live.ex` | Editor UI, form validation, and generation state. |
| `lib/kitten_tts_editor_web/components/` | Shared layouts and UI components. |
| `assets/` | Frontend JavaScript and Tailwind CSS sources. |
| `priv/static/audio/` | Generated WAV files served by the application. |
| `config/` | Development, test, production, and runtime configuration. |
| `test/` | Phoenix and LiveView tests. |

## Upstream references

- [KittenTTS](https://github.com/KittenML/KittenTTS)
- [KittenTTS Mini model](https://huggingface.co/KittenML/kitten-tts-mini-0.8)
- [Phoenix Framework](https://phoenixframework.org/)

defmodule KittenTtsEditorWeb.EditorLive do
  use KittenTtsEditorWeb, :live_view

  alias KittenTtsEditor.TTS.Worker

  @initial_text ""
  @initial_preset "stable"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Worker.subscribe()

    worker_status = Worker.status()
    text = @initial_text

    {:ok,
     assign(socket,
       page_title: "KittenTTS Studio",
       form: editor_form(text, nil, @initial_preset),
       text: text,
       voice: nil,
       voices: worker_status.voices,
       preset: @initial_preset,
       character_count: 0,
       word_count: 0,
       generation_status: :idle,
       worker_status: worker_status.status,
       backend: worker_status.backend,
       worker_error: worker_status.error,
       audio_url: nil,
       audio_duration: nil,
       generation_error: nil,
       task_ref: nil
     )}
  end

  @impl true
  def handle_event("update", %{"editor" => params}, socket) do
    text = Map.get(params, "text", "")
    voice = value_or_nil(Map.get(params, "voice"))
    preset = Map.get(params, "preset", @initial_preset)

    {:noreply,
     socket
     |> assign(
       form: editor_form(text, voice, preset),
       text: text,
       voice: voice,
       preset: preset,
       character_count: String.length(text),
       word_count: word_count(text)
     )
     |> assign(:generation_error, nil)}
  end

  def handle_event("generate", %{"editor" => params}, socket) do
    text = Map.get(params, "text", "")
    voice = value_or_nil(Map.get(params, "voice"))
    preset = Map.get(params, "preset", @initial_preset)

    cond do
      String.trim(text) == "" ->
        {:noreply,
         assign(socket, generation_error: "Enter the text you want to convert to speech.")}

      String.length(text) > 12_000 ->
        {:noreply, assign(socket, generation_error: "Text cannot exceed 12,000 characters.")}

      Regex.match?(~r/[\x{0600}-\x{06FF}\x{0750}-\x{077F}\x{08A0}-\x{08FF}]/u, text) ->
        {:noreply,
         assign(
           socket,
           generation_error:
             "KittenTTS Mini supports English text only. Arabic text is not supported."
         )}

      socket.assigns.generation_status == :generating ->
        {:noreply, socket}

      preset not in ["stable", "expressive"] ->
        {:noreply, assign(socket, generation_error: "Choose a valid generation preset.")}

      true ->
        task =
          Task.Supervisor.async_nolink(KittenTtsEditor.TaskSupervisor, fn ->
            Worker.generate(text, voice, preset)
          end)

        {:noreply,
         socket
         |> assign(
           form: editor_form(text, voice, preset),
           text: text,
           voice: voice,
           preset: preset,
           character_count: String.length(text),
           word_count: word_count(text),
           generation_status: :generating,
           generation_error: nil,
           audio_url: nil,
           audio_duration: nil,
           task_ref: task.ref
         )}
    end
  end

  @impl true
  def handle_info({ref, {:ok, result}}, %{assigns: %{task_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       generation_status: :done,
       audio_url: result.url,
       audio_duration: result.duration_seconds,
       generation_error: nil,
       task_ref: nil
     )}
  end

  def handle_info({ref, {:error, reason}}, %{assigns: %{task_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       generation_status: :error,
       generation_error: reason,
       task_ref: nil
     )}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{task_ref: ref}} = socket) do
    {:noreply,
     assign(socket,
       generation_status: :error,
       generation_error: "Generation failed: #{inspect(reason)}",
       task_ref: nil
     )}
  end

  def handle_info({:tts_worker_status, worker_status}, socket) do
    voices = worker_status.voices
    current_voice = socket.assigns.voice
    voice = if current_voice in voices, do: current_voice, else: List.first(voices)

    {:noreply,
     socket
     |> assign(
       worker_status: worker_status.status,
       backend: worker_status.backend,
       worker_error: worker_status.error,
       voices: voices,
       voice: voice
     )
     |> assign(:form, editor_form(socket.assigns.text, voice, socket.assigns.preset))}
  end

  defp editor_form(text, voice, preset) do
    Phoenix.Component.to_form(
      %{"text" => text, "voice" => voice || "", "preset" => preset},
      as: :editor
    )
  end

  defp value_or_nil(""), do: nil
  defp value_or_nil(value), do: value

  defp word_count(text) do
    text
    |> String.split()
    |> length()
  end

  defp worker_status_label(:ready, :native), do: "Optimized CPU runtime ready"
  defp worker_status_label(:starting, _backend), do: "Starting audio engine"
  defp worker_status_label(:not_loaded, _backend), do: "Ready to load on first use"
  defp worker_status_label(:loading, _backend), do: "Loading model"
  defp worker_status_label(:ready, _backend), do: "Model loaded and ready"
  defp worker_status_label(:error, _backend), do: "Audio engine unavailable"
  defp worker_status_label(_status, _backend), do: "Unknown engine status"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="relative">
        <div
          aria-hidden="true"
          class="pointer-events-none absolute -top-20 right-1/4 h-72 w-72 rounded-full bg-violet-500/10 blur-3xl"
        />

        <div class="relative">
          <div class="mb-8 flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <span class="grid size-12 place-items-center rounded-2xl border border-white/10 bg-white/[0.04] text-violet-300 shadow-lg shadow-violet-950/20">
                <.icon name="hero-musical-note" class="size-6" />
              </span>
              <div>
                <p class="text-xs font-semibold tracking-[0.2em] text-violet-300 uppercase">
                  AUDIO STUDIO
                </p>
                <p class="mt-1 text-sm text-slate-400">
                  KittenTTS Mini · English · ONNX / CPU
                </p>
              </div>
            </div>

            <div
              id="model-status"
              class="flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.04] px-3 py-2 text-xs text-slate-300"
              aria-live="polite"
            >
              <span class={[
                "size-2 rounded-full",
                @worker_status == :ready && "bg-emerald-400",
                @worker_status == :loading && "animate-pulse bg-amber-400",
                @worker_status == :error && "bg-rose-400",
                @worker_status not in [:ready, :loading, :error] && "bg-slate-500"
              ]} />
              {worker_status_label(@worker_status, @backend)}
            </div>
          </div>

          <div class="mb-7 max-w-3xl">
            <h1 class="text-3xl font-semibold tracking-tight text-white sm:text-4xl">
              Turn your words into speech.
            </h1>
            <p class="mt-3 max-w-2xl text-sm leading-7 text-slate-400 sm:text-base">
              Enter English text, choose one of eight voices, then listen to and download your audio.
            </p>
          </div>

          <.form
            for={@form}
            id="tts-editor-form"
            phx-change="update"
            phx-submit="generate"
            class="grid items-start gap-5 lg:grid-cols-[minmax(0,1.65fr)_minmax(17rem,0.75fr)]"
          >
            <section class="overflow-hidden rounded-3xl border border-white/10 bg-[#10141d]/90 shadow-2xl shadow-black/20">
              <div class="flex items-center justify-between border-b border-white/[0.07] px-5 py-4 sm:px-6">
                <div>
                  <h2 class="text-sm font-semibold text-slate-100">Text</h2>
                  <p class="mt-1 text-xs text-slate-500">
                    Type or paste the text you want to convert
                  </p>
                </div>
                <span class="rounded-lg border border-white/10 bg-white/[0.03] px-2.5 py-1 text-[11px] text-slate-400">
                  English text
                </span>
              </div>

              <div class="p-3 sm:p-5">
                <.input
                  field={@form[:text]}
                  type="textarea"
                  id="editor-text"
                  rows="13"
                  maxlength="12000"
                  dir="auto"
                  phx-debounce="200"
                  placeholder="Start typing here..."
                  class="min-h-72 w-full resize-y border-0 bg-transparent px-3 py-3 text-[15px] leading-8 text-slate-100 outline-none placeholder:text-slate-600 focus:outline-none focus:ring-0 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-violet-400/50 sm:px-4"
                  required
                />
              </div>

              <div class="flex flex-wrap items-center justify-between gap-3 border-t border-white/[0.07] px-5 py-3 text-xs text-slate-500 sm:px-6">
                <div class="flex items-center gap-4">
                  <span><span class="font-medium text-slate-300">{@character_count}</span> characters</span>
                  <span><span class="font-medium text-slate-300">{@word_count}</span> words</span>
                </div>
                <span>12,000 character limit</span>
              </div>
            </section>

            <aside class="space-y-5">
              <section class="rounded-3xl border border-white/10 bg-[#10141d]/90 p-5 shadow-xl shadow-black/10 sm:p-6">
                <h2 class="text-sm font-semibold text-white">Voice settings</h2>
                <p class="mt-1 text-xs leading-5 text-slate-500">Choose an English voice</p>

                <div class="mt-6 space-y-5">
                  <div>
                    <p id="voice-label" class="mb-2 text-xs font-medium text-slate-300">Voice</p>
                    <.input
                      field={@form[:voice]}
                      type="select"
                      id="editor-voice"
                      aria-labelledby="voice-label"
                      options={Enum.map(@voices, &{&1, &1})}
                      prompt={
                        if @voices == [],
                          do: "Voices appear after the model loads",
                          else: "Select a voice"
                      }
                      disabled={@voices == [] || @generation_status == :generating}
                      class="w-full rounded-xl border border-white/10 bg-[#0b0e15] px-3 py-3 text-sm text-slate-100 outline-none transition focus:border-violet-400/60 focus:ring-2 focus:ring-violet-400/15 disabled:cursor-not-allowed disabled:opacity-50"
                    />
                    <p class="mt-2 text-[11px] leading-5 text-slate-500">
                      The list comes from the model to ensure every option is supported.
                    </p>
                  </div>
                </div>

                <div class="mt-6 rounded-2xl border border-white/[0.07] bg-white/[0.025] p-4">
                  <div class="flex items-start gap-3">
                    <.icon
                      name="hero-information-circle"
                      class="mt-0.5 size-5 shrink-0 text-violet-300"
                    />
                    <p :if={@backend == :native} class="text-xs leading-6 text-emerald-100/80">
                      The optimized C++ CPU runtime is active. Model files are cached after the first download, but the CLI starts a new process for each request.
                    </p>
                    <p
                      :if={@backend == :python && @worker_status == :not_loaded}
                      class="text-xs leading-6 text-slate-400"
                    >
                      The model loads on the first request and stays in memory for subsequent requests.
                    </p>
                    <p
                      :if={@backend == :python && @worker_status == :loading}
                      class="text-xs leading-6 text-amber-200/80"
                    >
                      The model is loading. First-time setup may take a while, but it will not reload for each request.
                    </p>
                    <p
                      :if={@backend == :python && @worker_status == :ready}
                      class="text-xs leading-6 text-emerald-200/80"
                    >
                      KittenTTS Mini is ready. Subsequent requests skip the initial setup.
                    </p>
                    <p
                      :if={@backend == :python && @worker_status == :starting}
                      class="text-xs leading-6 text-slate-400"
                    >
                      Starting the audio service in the background.
                    </p>
                    <p :if={@worker_status == :error} class="text-xs leading-6 text-rose-200/90">
                      {@worker_error}
                    </p>
                  </div>
                </div>

                <button
                  id="generate-audio"
                  type="submit"
                  disabled={@generation_status == :generating || @worker_status == :error}
                  class="mt-5 flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-violet-400 px-4 py-3 text-sm font-semibold text-slate-950 shadow-lg shadow-violet-950/20 transition duration-200 hover:bg-violet-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-violet-300 disabled:cursor-not-allowed disabled:opacity-55"
                >
                  <.icon
                    :if={@generation_status == :generating}
                    name="hero-arrow-path"
                    class="size-4 motion-safe:animate-spin"
                  />
                  <.icon :if={@generation_status != :generating} name="hero-play" class="size-4" />
                  {if @generation_status == :generating,
                    do: "Generating audio...",
                    else: "Generate audio"}
                </button>
              </section>
            </aside>
          </.form>

          <div
            :if={@generation_status == :generating}
            id="generation-status"
            class="mt-5 flex items-center gap-3 rounded-2xl border border-violet-300/15 bg-violet-300/[0.06] px-5 py-4 text-sm text-violet-100"
            role="status"
            aria-live="polite"
          >
            <.icon name="hero-arrow-path" class="size-5 shrink-0 motion-safe:animate-spin" />
            <span>
              {if @worker_status == :loading,
                do: "Loading the model for the first time, then generation will begin...",
                else: "Generating audio. Keep this page open until it is ready."}
            </span>
          </div>

          <div
            :if={@generation_error}
            id="generation-error"
            class="mt-5 flex items-start gap-3 rounded-2xl border border-rose-300/20 bg-rose-400/[0.06] px-5 py-4 text-sm leading-6 text-rose-100"
            role="alert"
          >
            <.icon name="hero-exclamation-circle" class="mt-0.5 size-5 shrink-0 text-rose-300" />
            <span>{@generation_error}</span>
          </div>

          <section
            :if={@audio_url}
            id="generated-audio"
            class="mt-6 rounded-3xl border border-emerald-300/15 bg-emerald-300/[0.045] p-5 sm:p-6"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex items-center gap-3">
                <span class="grid size-10 place-items-center rounded-xl bg-emerald-300/10 text-emerald-200">
                  <.icon name="hero-check-circle" class="size-5" />
                </span>
                <div>
                  <h2 class="text-sm font-semibold text-white">Your audio is ready</h2>
                  <p class="mt-1 text-xs text-slate-400">
                    Generated in {@audio_duration} seconds
                  </p>
                </div>
              </div>
              <a
                id="download-audio"
                href={@audio_url}
                download
                class="inline-flex min-h-10 items-center gap-2 rounded-xl border border-white/10 bg-white/[0.04] px-4 py-2 text-xs font-semibold text-slate-200 transition hover:border-white/20 hover:bg-white/[0.08] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-violet-300"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download WAV
              </a>
            </div>
            <audio
              id="audio-preview"
              controls
              preload="metadata"
              src={@audio_url}
              class="mt-5 h-11 w-full accent-violet-400"
            >
              Your browser does not support audio playback.
            </audio>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end

defmodule KittenTtsEditor.TTS.Worker do
  use GenServer

  @topic "tts:worker"
  @max_line_length 1_048_576
  @max_characters 12_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(KittenTtsEditor.PubSub, @topic)
  end

  def generate(text, voice, preset) do
    GenServer.call(__MODULE__, {:generate, text, voice, preset}, :infinity)
  end

  @impl true
  def init(opts) do
    model =
      Keyword.get(opts, :model) ||
        System.get_env("KITTEN_TTS_MODEL") ||
        "KittenML/kitten-tts-mini-0.8"

    weights = Keyword.get(opts, :weights) || System.get_env("KITTEN_TTS_WEIGHTS") || "emb4"
    revision = Keyword.get(opts, :revision) || System.get_env("KITTEN_TTS_REVISION") || "main"
    decoder = Keyword.get(opts, :decoder) || System.get_env("KITTEN_TTS_DECODER") || "student_w4"
    threads = Keyword.get(opts, :threads) || System.get_env("KITTEN_TTS_THREADS") || "8"
    cache_dir = cache_dir(opts)
    script = Path.join(:code.priv_dir(:kitten_tts_editor), "python/tts_worker.py")

    state = %{
      backend: :python,
      executable: nil,
      port: nil,
      buffer: "",
      status: :starting,
      error: nil,
      model: model,
      voices: [],
      queue: :queue.new(),
      pending: nil,
      output_dir: Path.join(:code.priv_dir(:kitten_tts_editor), "static/audio"),
      cache_dir: cache_dir,
      decoder: decoder,
      revision: revision,
      threads: to_string(threads)
    }

    cpp_executable =
      if native_model?(model), do: cpp_executable(opts), else: :not_found

    case cpp_executable do
      {:ok, executable} ->
        voices = read_native_voices(state)

        state =
          state
          |> Map.put(:backend, :native)
          |> Map.put(:executable, executable)
          |> update_status(:ready, nil, voices)

        {:ok, state}

      {:error, message} ->
        {:ok, set_error(state, message)}

      :not_found ->
        python = python_executable(opts)

        cond do
          is_nil(python) ->
            {:ok,
             set_error(
               state,
               "Python was not found. Set KITTEN_TTS_PYTHON to the executable in an environment with kittenml installed."
             )}

          not File.regular?(script) ->
            {:ok, set_error(state, "KittenTTS worker script was not found at #{script}.")}

          true ->
            {:ok, start_worker(state, python, script, model, weights)}
        end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:backend, :status, :error, :model, :voices]), state}
  end

  def handle_call({:generate, text, voice, preset}, from, state)
      when is_binary(text) and preset in ["stable", "expressive"] do
    cond do
      state.status == :error ->
        {:reply, {:error, state.error}, state}

      String.trim(text) == "" ->
        {:reply, {:error, "Enter text before generating audio."}, state}

      String.length(text) > @max_characters ->
        {:reply, {:error, "Text cannot exceed 12,000 characters."}, state}

      true ->
        case File.mkdir_p(state.output_dir) do
          :ok ->
            id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
            output_path = Path.join(state.output_dir, "#{id}.wav")

            request = %{
              id: id,
              text: text,
              voice: voice,
              preset: preset,
              output_path: output_path
            }

            {:noreply, state |> enqueue({request, from}) |> dispatch_next()}

          {:error, reason} ->
            {:reply,
             {:error,
              "Could not prepare the audio output directory: #{:file.format_error(reason)}"},
             state}
        end
    end
  end

  def handle_call({:generate, _text, _voice, _preset}, _from, state) do
    {:reply, {:error, "Invalid generation settings."}, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.buffer <> line
    state = %{state | buffer: ""}
    {:noreply, state |> handle_worker_message(line) |> dispatch_next()}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    message = "KittenTTS engine stopped (exit code #{status})."
    {:noreply, fail_worker(state, message)}
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    {:noreply, fail_worker(state, "KittenTTS engine closed the connection unexpectedly.")}
  end

  def handle_info({:native_result, id, result}, %{backend: :native} = state) do
    state =
      case result do
        {:ok, duration} ->
          state
          |> update_status(:ready, nil, read_native_voices(state))
          |> finish_request(id, {:ok, duration})

        {:error, message} ->
          finish_request(state, id, {:error, message})
      end

    {:noreply, dispatch_next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp python_executable(opts) do
    configured = Keyword.get(opts, :python) || System.get_env("KITTEN_TTS_PYTHON")

    configured =
      configured ||
        Path.join(System.user_home!(), "kitten-tts/bin/python")

    cond do
      executable_file?(configured) ->
        configured

      Keyword.has_key?(opts, :python) or System.get_env("KITTEN_TTS_PYTHON") ->
        nil

      true ->
        System.find_executable("python3") || System.find_executable("python")
    end
  end

  defp cpp_executable(opts) do
    configured = Keyword.get(opts, :executable) || System.get_env("KITTEN_TTS_EXECUTABLE")
    default = Path.join(System.user_home!(), "kitten-tts-2-cpp/build/bin/kitten-tts")
    executable = configured || default

    cond do
      executable_file?(executable) ->
        {:ok, executable}

      configured ->
        {:error, "Invalid C++ runtime path: #{configured}"}

      true ->
        :not_found
    end
  end

  defp native_model?(model) do
    model
    |> String.downcase()
    |> String.contains?("kitten-tts-2")
  end

  defp cache_dir(opts) do
    Keyword.get(opts, :cache_dir) ||
      System.get_env("KITTEN_TTS_CACHE_DIR") ||
      Path.join(
        System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache"),
        "kitten-tts"
      )
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp start_worker(state, python, script, model, weights) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(python)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, @max_line_length},
          {:args, [String.to_charlist(script)]},
          {:env,
           [
             {~c"KITTEN_TTS_MODEL", String.to_charlist(model)},
             {~c"KITTEN_TTS_WEIGHTS", String.to_charlist(weights)}
           ]}
        ]
      )

    %{state | port: port}
  end

  defp enqueue(state, item) do
    %{state | queue: :queue.in(item, state.queue)}
  end

  defp dispatch_next(%{backend: :native, pending: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {request, from}}, queue} ->
        worker = self()

        case Task.Supervisor.start_child(KittenTtsEditor.TaskSupervisor, fn ->
               result = run_native(state, request)
               send(worker, {:native_result, request.id, result})
             end) do
          {:ok, _pid} ->
            %{state | queue: queue, pending: %{request: request, from: from}}

          {:error, reason} ->
            GenServer.reply(
              from,
              {:error, "Could not start the generation task: #{inspect(reason)}"}
            )

            %{state | queue: queue} |> dispatch_next()
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next(%{pending: nil, port: port} = state) when is_port(port) do
    case :queue.out(state.queue) do
      {{:value, {request, from}}, queue} ->
        message =
          request
          |> Map.take([:id, :text, :voice, :preset, :output_path])
          |> Jason.encode!()
          |> Kernel.<>("\n")

        if Port.command(port, message) do
          %{state | queue: queue, pending: %{request: request, from: from}}
        else
          GenServer.reply(from, {:error, "Could not send text to the KittenTTS engine."})
          %{state | queue: queue} |> dispatch_next()
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next(state), do: state

  defp run_native(state, request) do
    started_at = System.monotonic_time(:millisecond)

    args = [
      "--repo",
      state.model,
      "--revision",
      state.revision,
      "--decoder",
      state.decoder,
      "--cache-dir",
      state.cache_dir,
      "--threads",
      state.threads,
      "--decoder-threads",
      state.threads,
      "--preset",
      request.preset,
      "--text",
      request.text,
      "--output",
      request.output_path
    ]

    args =
      if request.voice do
        args ++ ["--voice", request.voice]
      else
        args
      end

    case System.cmd(state.executable, args, stderr_to_stdout: true) do
      {_output, status} when status == 0 ->
        case File.stat(request.output_path) do
          {:ok, %File.Stat{size: size}} when size > 0 ->
            duration = System.monotonic_time(:millisecond) - started_at
            {:ok, Float.round(duration / 1_000, 2)}

          _ ->
            {:error, "The C++ runtime finished without creating an audio file."}
        end

      {output, status} ->
        message = String.trim(output)

        message =
          if message == "", do: "Exit code #{status}", else: String.slice(message, 0, 2_000)

        {:error, "Generation failed in the C++ runtime: #{message}"}
    end
  rescue
    error in [ErlangError, ArgumentError] ->
      {:error, "Could not run the C++ runtime: #{Exception.message(error)}"}
  end

  defp read_native_voices(state) do
    revision = String.replace(state.revision, "/", "@")

    voices_path =
      Path.join([state.cache_dir, state.model, revision, "cpp", state.decoder, "voices.json"])

    with {:ok, contents} <- File.read(voices_path),
         {:ok, voices} when is_map(voices) <- Jason.decode(contents) do
      Map.keys(voices) |> Enum.sort()
    else
      _ -> []
    end
  end

  defp handle_worker_message(state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "online"}} ->
        update_status(state, :not_loaded, nil, [])

      {:ok, %{"type" => "loading"}} ->
        update_status(state, :loading, nil, state.voices)

      {:ok, %{"type" => "ready", "voices" => voices}} when is_list(voices) ->
        update_status(state, :ready, nil, voices)

      {:ok, %{"type" => "result", "id" => id, "duration_seconds" => duration}}
      when is_number(duration) ->
        finish_request(state, id, {:ok, duration})

      {:ok, %{"type" => "error", "id" => id, "error" => error}} when is_binary(error) ->
        finish_request(state, id, {:error, error})

      {:ok, %{"type" => "fatal", "error" => error}} when is_binary(error) ->
        fail_worker(state, error)

      {:error, reason} ->
        fail_worker(state, "Could not read the audio engine response: #{inspect(reason)}")

      _ ->
        fail_worker(state, "KittenTTS engine sent an unknown response.")
    end
  end

  defp finish_request(%{pending: %{request: request, from: from}} = state, id, result)
       when request.id == id do
    response =
      case result do
        {:ok, duration} ->
          {:ok,
           %{url: "/audio/#{Path.basename(request.output_path)}", duration_seconds: duration}}

        {:error, message} ->
          {:error, message}
      end

    GenServer.reply(from, response)
    %{state | pending: nil}
  end

  defp finish_request(state, _id, _result) do
    fail_worker(state, "Received a result that does not match the current generation request.")
  end

  defp update_status(state, status, error, voices) do
    state = %{state | status: status, error: error, voices: voices}

    Phoenix.PubSub.broadcast(
      KittenTtsEditor.PubSub,
      @topic,
      {:tts_worker_status, worker_status(state)}
    )

    state
  end

  defp set_error(state, message) do
    update_status(state, :error, message, state.voices)
  end

  defp fail_worker(state, message) do
    if state.pending do
      GenServer.reply(state.pending.from, {:error, message})
    end

    Enum.each(:queue.to_list(state.queue), fn {_request, from} ->
      GenServer.reply(from, {:error, message})
    end)

    state
    |> Map.put(:pending, nil)
    |> Map.put(:queue, :queue.new())
    |> set_error(message)
  end

  defp worker_status(state) do
    Map.take(state, [:backend, :status, :error, :model, :voices])
  end
end

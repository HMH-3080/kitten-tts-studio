import contextlib
import json
import os
import re
import sys
import time
import traceback


protocol_stdout = sys.stdout
model = None


def send_message(message):
    protocol_stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    protocol_stdout.flush()


def load_model():
    global model

    if model is not None:
        return model

    with contextlib.redirect_stdout(sys.stderr):
        from kittenml import KittenTTS

        model_name = os.environ.get(
            "KITTEN_TTS_MODEL", "KittenML/kitten-tts-mini-0.8"
        )
        if "kitten-tts-2" in model_name.lower():
            model = KittenTTS(
                model_name,
                weights=os.environ.get("KITTEN_TTS_WEIGHTS", "emb4"),
            )
        else:
            model = KittenTTS(model_name)

    return model


send_message({"type": "online"})

for line in sys.stdin:
    request = {}
    initializing = False

    try:
        request = json.loads(line)
        request_id = request["id"]
        text = request["text"]
        voice = request.get("voice")
        preset = request.get("preset", "stable")
        output_path = request["output_path"]

        if not isinstance(text, str) or not text.strip():
            raise ValueError("Enter text before generating audio.")

        if preset not in ("stable", "expressive"):
            raise ValueError("The selected generation preset is not supported.")

        if re.search(r"[\u0600-\u06ff\u0750-\u077f\u08a0-\u08ff]", text):
            raise ValueError(
                "KittenTTS Mini supports English text only. Arabic text is not supported."
            )

        if model is None:
            send_message({"type": "loading", "id": request_id})
            initializing = True

        with contextlib.redirect_stdout(sys.stderr):
            current_model = load_model()
            from kittenml.kittentts_legacy.model import KittenTTSOnnx

            is_onnx_model = isinstance(current_model, KittenTTSOnnx)
            voices = list(current_model.available_voices)
        initializing = False
        send_message({"type": "ready", "voices": voices})

        if voice and voice not in voices:
            raise ValueError(
                f"Voice '{voice}' is not available. Available voices: {', '.join(voices)}"
            )

        started_at = time.perf_counter()
        with contextlib.redirect_stdout(sys.stderr):
            if is_onnx_model:
                current_model.generate_to_file(
                    text,
                    output_path,
                    voice=voice or "Bruno",
                )
            else:
                current_model.generate_to_file(
                    text,
                    output_path,
                    voice=voice or None,
                    preset=preset,
                )

        if not os.path.isfile(output_path) or os.path.getsize(output_path) == 0:
            raise RuntimeError("The model finished without creating an audio file.")

        send_message(
            {
                "type": "result",
                "id": request_id,
                "duration_seconds": round(time.perf_counter() - started_at, 2),
            }
        )
    except Exception as error:
        output_path = request.get("output_path") if isinstance(request, dict) else None
        if output_path and os.path.exists(output_path):
            os.remove(output_path)

        traceback.print_exc(file=sys.stderr)
        if initializing:
            send_message({"type": "fatal", "error": str(error)})
            sys.exit(1)
        else:
            send_message(
                {
                    "type": "error",
                    "id": request.get("id") if isinstance(request, dict) else None,
                    "error": str(error),
                }
            )

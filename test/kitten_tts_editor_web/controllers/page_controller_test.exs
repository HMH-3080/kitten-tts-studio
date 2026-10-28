defmodule KittenTtsEditorWeb.PageControllerTest do
  use KittenTtsEditorWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / opens the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#tts-editor-form")
    assert has_element?(view, "#editor-text")
    assert has_element?(view, "#editor-voice")
    refute has_element?(view, "#editor-preset")
  end

  test "GET /editor opens the editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/editor")

    assert has_element?(view, "#tts-editor-form")
  end

  test "empty text is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/editor")

    view
    |> element("#tts-editor-form")
    |> render_submit(%{"editor" => %{"text" => "", "voice" => "", "preset" => "stable"}})

    assert has_element?(view, "#generation-error")
  end

  test "Arabic input displays an English-only model error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/editor")

    view
    |> element("#tts-editor-form")
    |> render_submit(%{"editor" => %{"text" => "مرحبا", "voice" => "", "preset" => "stable"}})

    assert has_element?(view, "#generation-error", "KittenTTS Mini")
  end
end

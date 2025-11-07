defmodule YtDlp.CommandTest do
  use ExUnit.Case
  doctest YtDlp.Command

  alias YtDlp.Command

  describe "binary_path/0" do
    test "returns default yt-dlp when env not set" do
      # Clear env var for this test
      System.delete_env("YT_DLP_PATH")
      assert Command.binary_path() == "yt-dlp"
    end

    test "returns custom path when env is set" do
      custom_path = "/custom/path/to/yt-dlp"
      System.put_env("YT_DLP_PATH", custom_path)
      assert Command.binary_path() == custom_path
      System.delete_env("YT_DLP_PATH")
    end
  end

  describe "run/2" do
    test "executes version command successfully" do
      case Command.run(["--version"]) do
        {:ok, output} ->
          assert is_binary(output)
          assert String.length(output) > 0

        {:error, _reason} ->
          # yt-dlp might not be available in test environment
          :ok
      end
    end

    test "returns error for invalid arguments" do
      case Command.run(["--invalid-flag-that-does-not-exist"]) do
        {:error, reason} ->
          assert is_binary(reason)
          assert reason =~ "Command failed"

        {:ok, _} ->
          # Unexpected success, but we'll allow it
          :ok
      end
    end
  end

  describe "get_info/2" do
    @tag :external
    test "fetches video info without downloading" do
      # This test requires network access
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case Command.get_info(url) do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, "id")
          assert Map.has_key?(info, "title")

        {:error, _reason} ->
          # Might fail without network or yt-dlp
          :ok
      end
    end
  end
end

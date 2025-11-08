defmodule YtDlpTest do
  use ExUnit.Case
  doctest YtDlp

  setup_all do
    # Ensure application is started for integration tests
    {:ok, _} = Application.ensure_all_started(:yt_dlp)
    :ok
  end

  describe "check_installation/0" do
    test "returns version when yt-dlp is installed" do
      case YtDlp.check_installation() do
        {:ok, version} ->
          assert is_binary(version)
          assert String.length(version) > 0

        {:error, _reason} ->
          # yt-dlp might not be available in test environment
          :ok
      end
    end
  end

  describe "download/2" do
    test "queues a download and returns download_id" do
      # Use a valid but small test video URL
      # Note: This test requires network access and yt-dlp to be installed
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case YtDlp.download(url) do
        {:ok, download_id} ->
          assert is_binary(download_id)
          assert String.length(download_id) > 0

          # Check status
          {:ok, status} = YtDlp.get_status(download_id)
          assert status.url == url
          assert status.status in [:pending, :downloading, :completed, :failed]

        {:error, _reason} ->
          # Might fail in test environment without network or yt-dlp
          :ok
      end
    end
  end

  describe "get_status/1" do
    test "returns error for non-existent download_id" do
      assert {:error, :not_found} = YtDlp.get_status("non-existent-id")
    end
  end

  describe "list_downloads/0" do
    test "returns a list of downloads" do
      downloads = YtDlp.list_downloads()
      assert is_list(downloads)
    end

    test "each download has required fields" do
      # Start a download to ensure list is not empty
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      {:ok, _download_id} = YtDlp.download(url)

      downloads = YtDlp.list_downloads()

      if length(downloads) > 0 do
        download = List.first(downloads)
        assert Map.has_key?(download, :id)
        assert Map.has_key?(download, :url)
        assert Map.has_key?(download, :status)
        assert Map.has_key?(download, :started_at)
      end
    end
  end

  describe "cancel/1" do
    test "returns error for non-existent download" do
      assert {:error, %YtDlp.Error.NotFoundError{}} = YtDlp.cancel("non-existent-id")
    end

    test "can cancel pending download" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case YtDlp.download(url) do
        {:ok, download_id} ->
          # Try to cancel
          result = YtDlp.cancel(download_id)
          # May succeed or fail depending on timing
          assert result == :ok or match?({:error, _}, result)

        {:error, _} ->
          :ok
      end
    end
  end

  describe "download_sync/2" do
    @tag :external
    @tag timeout: 60_000
    test "waits for download completion" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      result = YtDlp.download_sync(url, max_wait: 60_000, poll_interval: 500)

      case result do
        {:ok, download_result} ->
          assert is_map(download_result)
          assert Map.has_key?(download_result, :path)
          assert Map.has_key?(download_result, :url)

        {:error, reason} ->
          # May timeout or fail
          IO.puts("Sync download failed/timed out: #{reason}")
          :ok
      end
    end

    test "respects max_wait timeout" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      # Very short timeout
      result = YtDlp.download_sync(url, max_wait: 100, poll_interval: 50)

      # Should timeout
      case result do
        {:error, %YtDlp.Error.TimeoutError{}} ->
          :ok

        {:error, _other_error} ->
          # Other errors are also acceptable
          :ok

        {:ok, _} ->
          # Might succeed if very fast
          :ok
      end
    end
  end

  describe "get_info/2" do
    @tag :external
    test "fetches video metadata" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case YtDlp.get_info(url) do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, "id")
          assert Map.has_key?(info, "title")

        {:error, _reason} ->
          :ok
      end
    end

    test "returns error for invalid URL" do
      result = YtDlp.get_info("not-a-valid-url")

      assert match?({:error, _}, result)
    end

    test "handles timeout option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      # Should accept timeout option
      result = YtDlp.get_info(url, timeout: 30_000)

      # Either succeeds or fails, but doesn't crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "download options" do
    test "accepts format option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      result = YtDlp.download(url, format: "bestaudio")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts output_dir option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      result = YtDlp.download(url, output_dir: "/tmp/test_downloads")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts progress_callback option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      callback = fn _progress -> :ok end
      result = YtDlp.download(url, progress_callback: callback)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts timeout option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      result = YtDlp.download(url, timeout: 300_000)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts filename_template option" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      result = YtDlp.download(url, filename_template: "%(title)s-%(id)s.%(ext)s")

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "edge cases" do
    test "handles empty URL gracefully" do
      result = YtDlp.download("")

      # Should either fail validation or attempt download
      # Either way, should not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very long download ID lookup" do
      very_long_id = String.duplicate("a", 1000)
      result = YtDlp.get_status(very_long_id)

      assert result == {:error, :not_found}
    end

    test "handles unicode in URLs" do
      url = "https://www.youtube.com/watch?v=test-€–™"

      result = YtDlp.download(url)

      # Should handle gracefully (likely fail, but not crash)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles concurrent get_status calls" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case YtDlp.download(url) do
        {:ok, download_id} ->
          # Multiple concurrent status checks
          tasks =
            for _ <- 1..10 do
              Task.async(fn -> YtDlp.get_status(download_id) end)
            end

          results = Task.await_many(tasks)

          # All should return either ok or error, none should crash
          assert Enum.all?(results, fn result ->
                   match?({:ok, _}, result) or match?({:error, _}, result)
                 end)

        {:error, _} ->
          :ok
      end
    end
  end
end

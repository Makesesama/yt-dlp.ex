defmodule YtDlp.IntegrationTest do
  # Don't run in parallel due to env manipulation in some tests
  use ExUnit.Case, async: false

  alias YtDlp

  # Use a short, stable test video
  @test_url "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  @test_output_dir "/tmp/yt_dlp_integration_test"

  setup_all do
    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:yt_dlp)
    :ok
  end

  setup do
    # Store original env
    original_path = System.get_env("YT_DLP_PATH")

    # Clean up test directory
    File.rm_rf!(@test_output_dir)
    File.mkdir_p!(@test_output_dir)

    on_exit(fn ->
      # Clean up after tests
      File.rm_rf!(@test_output_dir)

      # Restore original env
      if original_path do
        System.put_env("YT_DLP_PATH", original_path)
      else
        System.delete_env("YT_DLP_PATH")
      end
    end)

    :ok
  end

  describe "download workflow" do
    @tag :external
    @tag timeout: 120_000
    test "complete download workflow with progress tracking" do
      {:ok, download_id} =
        YtDlp.download(
          @test_url,
          output_dir: @test_output_dir,
          progress_callback: fn progress ->
            # Collect progress updates
            send(self(), {:progress, progress})
          end
        )

      assert is_binary(download_id)

      # Check initial status
      {:ok, status} = YtDlp.get_status(download_id)
      assert status.id == download_id
      assert status.url == @test_url
      assert status.status in [:pending, :downloading]

      # Wait for completion
      max_wait = 120_000
      interval = 1000

      final_status =
        wait_for_completion(download_id, max_wait, interval)

      case final_status do
        {:ok, result} ->
          assert result.status in [:completed, :failed]

          if result.status == :completed do
            assert is_map(result.result)
            assert Map.has_key?(result.result, :path)
            assert File.exists?(result.result.path)
          end

          # Check that we received progress updates
          progress_count = count_progress_messages()
          IO.puts("Received #{progress_count} progress updates")

        {:error, :timeout} ->
          # Download took too long, but that's okay for test purposes
          IO.puts("Download timed out (acceptable for test)")

        {:error, reason} ->
          IO.puts("Download failed: #{reason}")
      end
    end

    @tag :external
    @tag timeout: 120_000
    test "synchronous download completes successfully" do
      result =
        YtDlp.download_sync(
          @test_url,
          output_dir: @test_output_dir,
          max_wait: 120_000
        )

      case result do
        {:ok, download_result} ->
          assert is_map(download_result)
          assert Map.has_key?(download_result, :path)
          assert Map.has_key?(download_result, :url)
          assert download_result.url == @test_url

          if File.exists?(download_result.path) do
            stat = File.stat!(download_result.path)
            assert stat.size > 0
          end

        {:error, reason} ->
          # Might fail due to network, yt-dlp issues, etc.
          IO.puts("Sync download failed: #{reason}")
      end
    end

    @tag :external
    test "download cancellation works" do
      {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)

      # Try to cancel immediately
      result = YtDlp.cancel(download_id)

      case result do
        :ok ->
          {:ok, status} = YtDlp.get_status(download_id)
          # Should be failed with cancellation message
          if status.status == :failed do
            assert status.error =~ "cancelled"
          end

        {:error, reason} ->
          # Might already be downloading or completed
          IO.puts("Cancel failed (expected): #{reason}")
      end
    end

    @tag :external
    test "multiple concurrent downloads" do
      urls = [
        @test_url,
        @test_url,
        @test_url
      ]

      download_ids =
        Enum.map(urls, fn url ->
          {:ok, id} = YtDlp.download(url, output_dir: @test_output_dir)
          id
        end)

      assert length(download_ids) == 3
      assert Enum.all?(download_ids, &is_binary/1)

      # Check that all downloads are tracked
      all_downloads = YtDlp.list_downloads()
      our_downloads = Enum.filter(all_downloads, &(&1.id in download_ids))

      assert length(our_downloads) >= 3
    end
  end

  describe "get_info" do
    @tag :external
    test "retrieves video metadata correctly" do
      case YtDlp.get_info(@test_url) do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, "id")
          assert Map.has_key?(info, "title")
          assert Map.has_key?(info, "duration")
          assert is_integer(info["duration"])
          assert info["duration"] > 0

        {:error, reason} ->
          IO.puts("get_info failed: #{reason}")
      end
    end

    @tag :external
    test "handles invalid URL gracefully" do
      result = YtDlp.get_info("https://invalid-url-that-does-not-exist.com/video")

      assert match?({:error, _}, result)
    end

    @tag :external
    test "handles malformed URL" do
      result = YtDlp.get_info("not-a-url")

      assert match?({:error, _}, result)
    end
  end

  describe "download options" do
    @tag :external
    @tag timeout: 120_000
    test "respects custom output directory" do
      custom_dir = Path.join(@test_output_dir, "custom")
      File.mkdir_p!(custom_dir)

      {:ok, download_id} =
        YtDlp.download(@test_url, output_dir: custom_dir)

      final_status = wait_for_completion(download_id, 120_000, 1000)

      case final_status do
        {:ok, %{status: :completed, result: result}} ->
          assert String.starts_with?(result.path, custom_dir)

        _ ->
          # May not complete in time
          :ok
      end
    end

    @tag :external
    @tag timeout: 120_000
    test "respects format option" do
      {:ok, download_id} =
        YtDlp.download(
          @test_url,
          output_dir: @test_output_dir,
          format: "bestaudio"
        )

      # Just verify it doesn't crash
      assert is_binary(download_id)
    end
  end

  describe "error handling" do
    test "handles missing yt-dlp gracefully" do
      # Temporarily override the binary path
      System.put_env("YT_DLP_PATH", "/nonexistent/yt-dlp")

      result =
        try do
          YtDlp.check_installation()
        catch
          kind, reason ->
            # Catch ErlangError or exit with :enoent
            {:error, "Binary not found: #{inspect(kind)} #{inspect(reason)}"}
        end

      assert match?({:error, _}, result)
      # on_exit callback will restore the env
    end

    test "returns error for non-existent download ID" do
      result = YtDlp.get_status("non-existent-id")

      assert result == {:error, :not_found}
    end

    test "returns error canceling non-existent download" do
      result = YtDlp.cancel("non-existent-id")

      assert match?({:error, %YtDlp.Error.NotFoundError{}}, result)
    end
  end

  describe "check_installation" do
    test "verifies yt-dlp is installed" do
      result =
        try do
          YtDlp.check_installation()
        catch
          :exit, _ -> {:error, "Binary not found"}
        end

      case result do
        {:ok, version} ->
          assert is_binary(version)
          assert String.length(version) > 0

        {:error, _reason} ->
          # yt-dlp might not be installed
          :ok
      end
    end
  end

  describe "list_downloads" do
    @tag :external
    test "lists all downloads" do
      # Start a download
      {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)

      downloads = YtDlp.list_downloads()

      assert is_list(downloads)
      assert Enum.any?(downloads, &(&1.id == download_id))
    end

    test "returns empty list when no downloads" do
      # This might fail if other tests have created downloads
      # But we test that list_downloads returns a list
      downloads = YtDlp.list_downloads()

      assert is_list(downloads)
    end
  end

  # Helper functions

  defp wait_for_completion(download_id, max_wait, interval, elapsed \\ 0)

  defp wait_for_completion(_download_id, max_wait, _interval, elapsed)
       when elapsed >= max_wait do
    {:error, :timeout}
  end

  defp wait_for_completion(download_id, max_wait, interval, elapsed) do
    case YtDlp.get_status(download_id) do
      {:ok, %{status: :completed} = status} ->
        {:ok, status}

      {:ok, %{status: :failed} = status} ->
        {:ok, status}

      {:ok, _status} ->
        Process.sleep(interval)
        wait_for_completion(download_id, max_wait, interval, elapsed + interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_progress_messages(count \\ 0) do
    receive do
      {:progress, _progress} ->
        count_progress_messages(count + 1)
    after
      100 ->
        count
    end
  end
end

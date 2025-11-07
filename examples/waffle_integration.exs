#!/usr/bin/env elixir

# Example: Download video and upload to S3 with Waffle
# Run with: mix run examples/waffle_integration.exs

defmodule VideoProcessor do
  @moduledoc """
  Example module showing how to integrate YtDlp with Waffle for S3 uploads.

  This demonstrates the complete workflow:
  1. Download video with yt-dlp
  2. Track progress in real-time
  3. Upload to S3 with Waffle when complete
  4. Clean up local file
  """

  require Logger

  @doc """
  Downloads a video and uploads it to S3.

  ## Options

    * `:progress_handler` - PID to send progress updates to (optional)
    * `:format` - Video format (default: "best")
    * `:cleanup` - Whether to delete local file after upload (default: true)

  ## Returns

    * `{:ok, s3_url, metadata}` - Success with S3 URL and video metadata
    * `{:error, reason}` - Failure
  """
  def download_and_upload(video_url, user, opts \\ []) do
    progress_handler = Keyword.get(opts, :progress_handler)
    format = Keyword.get(opts, :format, "best")
    cleanup = Keyword.get(opts, :cleanup, true)

    Logger.info("Starting download for #{video_url}")

    # Step 1: Get video info first
    with {:ok, video_info} <- YtDlp.get_info(video_url),
         # Step 2: Start download with progress tracking
         {:ok, download_id} <- start_download(video_url, format, progress_handler),
         # Step 3: Wait for download to complete
         {:ok, file_path} <- wait_for_download(download_id),
         # Step 4: Upload to S3
         {:ok, s3_url} <- upload_to_s3(file_path, user, video_info) do
      # Step 5: Cleanup local file if requested
      if cleanup do
        File.rm(file_path)
        Logger.info("Cleaned up local file: #{file_path}")
      end

      {:ok, s3_url, extract_metadata(video_info)}
    else
      {:error, reason} = error ->
        Logger.error("Video processing failed: #{reason}")
        error
    end
  end

  @doc """
  Downloads multiple videos concurrently and uploads them to S3.
  """
  def batch_download_and_upload(video_urls, user, opts \\ []) do
    video_urls
    |> Task.async_stream(
      fn url ->
        download_and_upload(url, user, opts)
      end,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  # Private functions

  defp start_download(video_url, format, progress_handler) do
    progress_callback =
      if progress_handler do
        fn progress ->
          send(progress_handler, {:download_progress, video_url, progress})
        end
      else
        fn progress ->
          # Default: log every 10%
          if progress.percent && rem(trunc(progress.percent), 10) == 0 do
            Logger.info(
              "Download progress: #{trunc(progress.percent)}% - #{progress.speed} - ETA: #{progress.eta}"
            )
          end
        end
      end

    YtDlp.download(video_url,
      format: format,
      output_dir: "/tmp/video_uploads",
      progress_callback: progress_callback
    )
  end

  defp wait_for_download(download_id, max_wait \\ 1_800_000) do
    # Poll every 2 seconds
    wait_for_download_loop(download_id, max_wait, 0, 2000)
  end

  defp wait_for_download_loop(download_id, max_wait, elapsed, interval) when elapsed >= max_wait do
    # Timeout - cancel the download
    YtDlp.cancel(download_id)
    {:error, "Download timeout after #{max_wait}ms"}
  end

  defp wait_for_download_loop(download_id, max_wait, elapsed, interval) do
    case YtDlp.get_status(download_id) do
      {:ok, %{status: :completed, result: result}} ->
        {:ok, result.path}

      {:ok, %{status: :failed, error: error}} ->
        {:error, "Download failed: #{error}"}

      {:ok, %{status: _}} ->
        Process.sleep(interval)
        wait_for_download_loop(download_id, max_wait, elapsed + interval, interval)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_to_s3(file_path, user, video_info) do
    Logger.info("Uploading to S3: #{file_path}")

    # In a real app, you'd use Waffle like this:
    # case MyApp.VideoUploader.store({file_path, user}) do
    #   {:ok, filename} ->
    #     s3_url = MyApp.VideoUploader.url({filename, user})
    #     {:ok, s3_url}
    #   error ->
    #     error
    # end

    # For demo purposes, simulate the upload
    simulate_s3_upload(file_path, user, video_info)
  end

  defp simulate_s3_upload(file_path, _user, video_info) do
    # Simulate upload time based on file size
    file_size = File.stat!(file_path).size
    upload_time = min(trunc(file_size / 1_000_000 * 100), 2000)

    Logger.info("Simulating S3 upload (#{upload_time}ms)...")
    Process.sleep(upload_time)

    filename = Path.basename(file_path)
    s3_url = "https://s3.amazonaws.com/my-bucket/videos/#{filename}"

    Logger.info("Upload complete: #{s3_url}")
    {:ok, s3_url}
  end

  defp extract_metadata(video_info) do
    %{
      title: video_info["title"],
      duration: video_info["duration"],
      uploader: video_info["uploader"],
      upload_date: video_info["upload_date"],
      view_count: video_info["view_count"],
      thumbnail: video_info["thumbnail"]
    }
  end
end

# ============================================================================
# Example Usage
# ============================================================================

IO.puts("=== Waffle Integration Example ===\n")

# Ensure application is started
{:ok, _} = Application.ensure_all_started(:yt_dlp)

# Example video URL (short, free video for testing)
video_url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
user = %{id: 123, name: "demo_user"}

IO.puts("Processing video: #{video_url}\n")

# Example 1: Simple download and upload
IO.puts("1. Simple download and upload...")

case VideoProcessor.download_and_upload(video_url, user) do
  {:ok, s3_url, metadata} ->
    IO.puts("   ✓ Success!")
    IO.puts("     S3 URL: #{s3_url}")
    IO.puts("     Title: #{metadata.title}")
    IO.puts("     Duration: #{metadata.duration}s")
    IO.puts("     Uploader: #{metadata.uploader}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 2: Download with progress handler
IO.puts("2. Download with custom progress handler...")

# Start a progress monitor task
progress_monitor =
  Task.async(fn ->
    receive_progress_loop()
  end)

case VideoProcessor.download_and_upload(video_url, user, progress_handler: progress_monitor.pid) do
  {:ok, s3_url, _metadata} ->
    IO.puts("\n   ✓ Upload complete: #{s3_url}")

  {:error, reason} ->
    IO.puts("\n   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 3: Batch processing
IO.puts("3. Batch download and upload (multiple videos)...")

video_urls = [
  "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
  "https://www.youtube.com/watch?v=jNQXAC9IVRw"
]

results = VideoProcessor.batch_download_and_upload(video_urls, user)

Enum.with_index(results, 1)
|> Enum.each(fn {result, index} ->
  case result do
    {:ok, s3_url, metadata} ->
      IO.puts("   ✓ Video #{index}: #{metadata.title}")
      IO.puts("     URL: #{s3_url}")

    {:error, reason} ->
      IO.puts("   ✗ Video #{index} failed: #{reason}")
  end
end)

IO.puts("")
IO.puts("=== Example Complete ===")

# Helper function for progress monitoring
defp receive_progress_loop do
  receive do
    {:download_progress, url, progress} ->
      IO.write(
        "\r   Progress: #{Float.round(progress.percent || 0.0, 1)}% | #{progress.speed || "N/A"} | ETA: #{progress.eta || "N/A"}    "
      )

      receive_progress_loop()
  after
    5000 ->
      # Timeout after 5 seconds of no updates
      :ok
  end
end

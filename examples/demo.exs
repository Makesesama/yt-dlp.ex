#!/usr/bin/env elixir

# Example usage of YtDlp.ex
# Run with: mix run examples/demo.exs
# Or: elixir -S mix run examples/demo.exs

IO.puts("=== YtDlp.ex Demo ===\n")

# Start the application
{:ok, _} = Application.ensure_all_started(:yt_dlp)

# Example 1: Check if yt-dlp is installed
IO.puts("1. Checking yt-dlp installation...")

case YtDlp.check_installation() do
  {:ok, version} ->
    IO.puts("   ✓ yt-dlp version: #{version}")

  {:error, reason} ->
    IO.puts("   ✗ yt-dlp not found: #{reason}")
    IO.puts("   Please install yt-dlp first (included in nix flake)")
    System.halt(1)
end

IO.puts("")

# Example 2: Get video information without downloading
IO.puts("2. Getting video information...")
# Using a short, free video for testing
test_url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

case YtDlp.get_info(test_url) do
  {:ok, info} ->
    IO.puts("   ✓ Video info retrieved:")
    IO.puts("     Title: #{info["title"]}")
    IO.puts("     Duration: #{info["duration"]} seconds")
    IO.puts("     Uploader: #{info["uploader"]}")
    IO.puts("     View count: #{info["view_count"]}")

  {:error, reason} ->
    IO.puts("   ✗ Failed to get info: #{reason}")
end

IO.puts("")

# Example 3: Simple async download
IO.puts("3. Simple async download (queued)...")

case YtDlp.download(test_url) do
  {:ok, download_id} ->
    IO.puts("   ✓ Download queued with ID: #{download_id}")

    # Check initial status
    {:ok, status} = YtDlp.get_status(download_id)
    IO.puts("   Status: #{status.status}")

  {:error, reason} ->
    IO.puts("   ✗ Failed to queue download: #{reason}")
end

IO.puts("")

# Example 4: Download with progress tracking
IO.puts("4. Download with real-time progress...")

{:ok, download_id} =
  YtDlp.download(
    test_url,
    progress_callback: fn progress ->
      # Clear line and show progress
      percent = progress.percent || 0.0
      speed = progress.speed || "N/A"
      eta = progress.eta || "N/A"

      IO.write(
        "\r   Progress: #{Float.round(percent, 1)}% | Speed: #{speed} | ETA: #{eta}    "
      )
    end
  )

IO.puts("   Download ID: #{download_id}")

# Monitor until complete
monitor_download(download_id)

IO.puts("")

# Example 5: Synchronous download
IO.puts("5. Synchronous download (wait for completion)...")

case YtDlp.download_sync(test_url, max_wait: 60_000) do
  {:ok, result} ->
    IO.puts("   ✓ Download completed!")
    IO.puts("     File path: #{result.path}")
    IO.puts("     File exists: #{File.exists?(result.path)}")

    if File.exists?(result.path) do
      stat = File.stat!(result.path)
      IO.puts("     File size: #{format_bytes(stat.size)}")
    end

  {:error, reason} ->
    IO.puts("   ✗ Download failed: #{reason}")
end

IO.puts("")

# Example 6: Cancellation
IO.puts("6. Download cancellation...")

{:ok, download_id} = YtDlp.download(test_url)
IO.puts("   Started download: #{download_id}")

# Wait a moment
Process.sleep(100)

# Cancel it
case YtDlp.cancel(download_id) do
  :ok ->
    IO.puts("   ✓ Download cancelled successfully")

    {:ok, status} = YtDlp.get_status(download_id)
    IO.puts("   Final status: #{status.status}")

    if status.error do
      IO.puts("   Error: #{status.error}")
    end

  {:error, reason} ->
    IO.puts("   ✗ Failed to cancel: #{reason}")
end

IO.puts("")

# Example 7: Multiple concurrent downloads
IO.puts("7. Multiple concurrent downloads...")

test_urls = [
  "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
  "https://www.youtube.com/watch?v=jNQXAC9IVRw",
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
]

download_ids =
  Enum.map(test_urls, fn url ->
    {:ok, id} = YtDlp.download(url)
    IO.puts("   Queued: #{id}")
    id
  end)

IO.puts("   Total downloads queued: #{length(download_ids)}")
IO.puts("")

# Example 8: List all downloads
IO.puts("8. Listing all downloads...")

downloads = YtDlp.list_downloads()
IO.puts("   Total downloads: #{length(downloads)}")

Enum.each(downloads, fn download ->
  status_icon =
    case download.status do
      :completed -> "✓"
      :failed -> "✗"
      :downloading -> "⬇"
      :pending -> "⏳"
    end

  progress_str =
    if download.progress do
      " (#{Float.round(download.progress.percent || 0.0, 1)}%)"
    else
      ""
    end

  IO.puts("   #{status_icon} #{download.status}#{progress_str} - #{String.slice(download.url, 0..50)}...")
end)

IO.puts("")

# Example 9: Custom download options
IO.puts("9. Custom download with specific format...")

{:ok, download_id} =
  YtDlp.download(
    test_url,
    format: "bestaudio",
    output_dir: "/tmp/yt_dlp_demo",
    filename_template: "%(title)s-%(id)s.%(ext)s"
  )

IO.puts("   Queued audio-only download: #{download_id}")

# Wait for it
result = wait_for_download_sync(download_id)

case result do
  {:ok, path} ->
    IO.puts("   ✓ Downloaded to: #{path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 10: Simulated S3 upload workflow
IO.puts("10. Simulated workflow: Download → Upload to S3...")

defmodule S3Uploader do
  # Simulated S3 uploader (replace with real Waffle implementation)
  def upload(file_path, _metadata) do
    IO.puts("      [S3] Uploading #{Path.basename(file_path)}...")
    Process.sleep(500)
    IO.puts("      [S3] Upload complete!")
    {:ok, "https://s3.example.com/videos/#{Path.basename(file_path)}"}
  end
end

{:ok, download_id} =
  YtDlp.download(
    test_url,
    progress_callback: fn progress ->
      if progress.percent && rem(trunc(progress.percent), 10) == 0 do
        IO.puts("      [Download] #{trunc(progress.percent)}% complete...")
      end
    end
  )

case wait_for_download_sync(download_id, 120_000) do
  {:ok, file_path} ->
    IO.puts("   ✓ Download complete: #{file_path}")

    # Simulate upload to S3 with Waffle
    case S3Uploader.upload(file_path, %{user_id: 123}) do
      {:ok, s3_url} ->
        IO.puts("   ✓ Uploaded to S3: #{s3_url}")

        # Clean up local file
        File.rm(file_path)
        IO.puts("   ✓ Cleaned up local file")

      {:error, reason} ->
        IO.puts("   ✗ S3 upload failed: #{reason}")
    end

  {:error, reason} ->
    IO.puts("   ✗ Download failed: #{reason}")
end

IO.puts("")
IO.puts("=== Demo Complete ===")

# Helper functions

defp monitor_download(download_id) do
  {:ok, status} = YtDlp.get_status(download_id)

  case status.status do
    :completed ->
      IO.puts("\n   ✓ Download complete!")
      IO.puts("     File: #{status.result.path}")

    :failed ->
      IO.puts("\n   ✗ Download failed: #{status.error}")

    _ ->
      Process.sleep(1000)
      monitor_download(download_id)
  end
end

defp wait_for_download_sync(download_id, max_wait \\ 60_000) do
  wait_for_download_sync(download_id, max_wait, 0)
end

defp wait_for_download_sync(download_id, max_wait, elapsed) when elapsed >= max_wait do
  {:error, "Timeout waiting for download"}
end

defp wait_for_download_sync(download_id, max_wait, elapsed) do
  {:ok, status} = YtDlp.get_status(download_id)

  case status.status do
    :completed -> {:ok, status.result.path}
    :failed -> {:error, status.error}
    _ ->
      Process.sleep(1000)
      wait_for_download_sync(download_id, max_wait, elapsed + 1000)
  end
end

defp format_bytes(bytes) do
  cond do
    bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
    bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
    bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
    true -> "#{bytes} bytes"
  end
end

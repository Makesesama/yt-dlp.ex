defmodule MyApp.Workers.VideoDownloadWorker do
  @moduledoc """
  Oban worker for downloading videos with yt-dlp.

  This worker demonstrates different approaches for integrating YtDlp with Oban:
  1. Synchronous download (blocks the worker)
  2. Asynchronous download with polling
  3. Download with progress updates via PubSub
  """

  use Oban.Worker,
    queue: :video_downloads,
    max_attempts: 3,
    priority: 1

  require Logger

  alias MyApp.Workers.VideoDownloadCompletionWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url, "user_id" => user_id} = args}) do
    strategy = Map.get(args, "strategy", "sync")
    output_dir = Map.get(args, "output_dir", System.tmp_dir!() |> Path.join("yt_dlp"))

    case strategy do
      "sync" -> download_sync(url, user_id, output_dir)
      "async" -> download_async(url, user_id, output_dir)
      "async_pubsub" -> download_async_with_pubsub(url, user_id, output_dir)
    end
  end

  # Strategy 1: Synchronous Download (Simple, blocks the worker)
  # Good for: Simple use cases where you want the job to finish when download is done
  defp download_sync(url, user_id, output_dir) do
    Logger.info("Starting sync download for user #{user_id}: #{url}")

    case YtDlp.download_sync(url, output_dir: output_dir, max_wait: 1_800_000) do
      {:ok, %{path: file_path}} ->
        Logger.info("Download completed: #{file_path}")

        # Process the downloaded file (e.g., upload to S3)
        case upload_to_s3(file_path, user_id) do
          {:ok, s3_url} ->
            # Clean up local file
            File.rm(file_path)

            # Update database
            update_user_video(user_id, %{
              status: "completed",
              s3_url: s3_url,
              completed_at: DateTime.utc_now()
            })

            {:ok, %{s3_url: s3_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Download failed: #{reason}")
        {:error, reason}
    end
  end

  # Strategy 2: Async Download with Polling (More complex, non-blocking)
  # Good for: When you want to free up the worker quickly
  # Note: This requires Oban Pro's `chunk` callback or a separate polling mechanism
  defp download_async(url, user_id, output_dir) do
    Logger.info("Starting async download for user #{user_id}: #{url}")

    case YtDlp.download(url, output_dir: output_dir) do
      {:ok, download_id} ->
        # Store download_id in database for later tracking
        update_user_video(user_id, %{
          status: "downloading",
          download_id: download_id,
          started_at: DateTime.utc_now()
        })

        # Schedule a completion check job
        %{
          user_id: user_id,
          download_id: download_id,
          url: url,
          output_dir: output_dir
        }
        |> VideoDownloadCompletionWorker.new(schedule_in: 10)
        |> Oban.insert()

        {:ok, %{download_id: download_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Strategy 3: Async with PubSub Progress Updates (Most advanced)
  # Good for: Real-time progress tracking in LiveView
  defp download_async_with_pubsub(url, user_id, output_dir) do
    Logger.info("Starting async download with PubSub for user #{user_id}: #{url}")

    case YtDlp.download(
           url,
           output_dir: output_dir,
           progress_callback: fn progress ->
             # Broadcast progress to PubSub
             Phoenix.PubSub.broadcast(
               MyApp.PubSub,
               "user:#{user_id}:downloads",
               {:download_progress, url, progress}
             )
           end
         ) do
      {:ok, download_id} ->
        # Start a monitoring task
        Task.start(fn ->
          monitor_download(download_id, user_id, url, output_dir)
        end)

        {:ok, %{download_id: download_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Monitor download completion
  defp monitor_download(download_id, user_id, url, _output_dir) do
    case YtDlp.get_status(download_id) do
      {:ok, %{status: :completed, result: %{path: file_path}}} ->
        Logger.info("Download completed: #{file_path}")

        # Broadcast completion
        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "user:#{user_id}:downloads",
          {:download_completed, url, file_path}
        )

        # Upload to S3
        case upload_to_s3(file_path, user_id) do
          {:ok, s3_url} ->
            File.rm(file_path)

            Phoenix.PubSub.broadcast(
              MyApp.PubSub,
              "user:#{user_id}:downloads",
              {:upload_completed, url, s3_url}
            )

          {:error, reason} ->
            Phoenix.PubSub.broadcast(
              MyApp.PubSub,
              "user:#{user_id}:downloads",
              {:upload_failed, url, reason}
            )
        end

      {:ok, %{status: :failed, error: error}} ->
        Logger.error("Download failed: #{error}")

        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "user:#{user_id}:downloads",
          {:download_failed, url, error}
        )

      {:ok, %{status: status}} when status in [:pending, :downloading] ->
        # Still in progress, check again
        Process.sleep(2000)
        monitor_download(download_id, user_id, url, _output_dir)

      {:error, :not_found} ->
        Logger.error("Download ID not found: #{download_id}")
    end
  end

  # Simulated S3 upload
  defp upload_to_s3(file_path, user_id) do
    # In a real app, use ExAws or similar
    Logger.info("Uploading #{file_path} to S3 for user #{user_id}")

    # Simulate upload
    Process.sleep(500)

    s3_key = "videos/user_#{user_id}/#{Path.basename(file_path)}"
    s3_url = "https://s3.amazonaws.com/my-bucket/#{s3_key}"

    {:ok, s3_url}
  end

  # Simulated database update
  defp update_user_video(user_id, attrs) do
    Logger.info("Updating video for user #{user_id}: #{inspect(attrs)}")
    # In a real app: MyApp.Repo.update(...)
    :ok
  end
end

defmodule MyApp.Workers.VideoDownloadCompletionWorker do
  @moduledoc """
  Worker that polls for download completion.
  Used with Strategy 2 (async with polling).
  """

  use Oban.Worker,
    queue: :video_download_checks,
    max_attempts: 100

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "download_id" => download_id,
          "user_id" => user_id,
          "url" => url,
          "output_dir" => output_dir
        },
        attempt: attempt
      }) do
    case YtDlp.get_status(download_id) do
      {:ok, %{status: :completed, result: %{path: file_path}}} ->
        Logger.info("Download completed: #{file_path}")

        # Upload to S3 and clean up
        case upload_to_s3(file_path, user_id) do
          {:ok, s3_url} ->
            File.rm(file_path)

            update_user_video(user_id, %{
              status: "completed",
              s3_url: s3_url,
              completed_at: DateTime.utc_now()
            })

            {:ok, %{s3_url: s3_url}}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{status: :failed, error: error}} ->
        Logger.error("Download failed: #{error}")

        update_user_video(user_id, %{
          status: "failed",
          error: error,
          failed_at: DateTime.utc_now()
        })

        {:error, error}

      {:ok, %{status: status}} when status in [:pending, :downloading] ->
        # Still in progress
        if attempt < 100 do
          # Reschedule check in 10 seconds
          Logger.info("Download still #{status}, rescheduling check (attempt #{attempt})")
          {:snooze, 10}
        else
          Logger.error("Download timed out after #{attempt} attempts")
          {:error, "Download timed out"}
        end

      {:error, :not_found} ->
        {:error, "Download not found"}
    end
  end

  defp upload_to_s3(file_path, user_id) do
    Logger.info("Uploading #{file_path} to S3 for user #{user_id}")
    Process.sleep(500)

    s3_url =
      "https://s3.amazonaws.com/my-bucket/videos/user_#{user_id}/#{Path.basename(file_path)}"

    {:ok, s3_url}
  end

  defp update_user_video(user_id, attrs) do
    Logger.info("Updating video for user #{user_id}: #{inspect(attrs)}")
    :ok
  end
end

# Usage Examples:

# 1. Enqueue a simple synchronous download job
# MyApp.Workers.VideoDownloadWorker.new(%{
#   url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
#   user_id: 123,
#   strategy: "sync"
# })
# |> Oban.insert()

# 2. Enqueue an async download with polling
# MyApp.Workers.VideoDownloadWorker.new(%{
#   url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
#   user_id: 123,
#   strategy: "async"
# })
# |> Oban.insert()

# 3. Enqueue an async download with PubSub progress updates
# MyApp.Workers.VideoDownloadWorker.new(%{
#   url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
#   user_id: 123,
#   strategy: "async_pubsub"
# })
# |> Oban.insert()

# Batch downloads with Oban.insert_all:
# urls = [
#   "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
#   "https://www.youtube.com/watch?v=jNQXAC9IVRw"
# ]
#
# jobs =
#   Enum.map(urls, fn url ->
#     MyApp.Workers.VideoDownloadWorker.new(%{
#       url: url,
#       user_id: 123,
#       strategy: "sync"
#     })
#   end)
#
# Oban.insert_all(jobs)

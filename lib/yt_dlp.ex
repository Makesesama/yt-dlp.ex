defmodule YtDlp do
  @moduledoc """
  Elixir wrapper for yt-dlp with GenServer-based download management.

  This library provides a high-level interface for downloading videos using
  yt-dlp. It manages concurrent downloads, tracks status, and provides both
  synchronous and asynchronous download options.

  ## Features

    * Asynchronous video downloads with status tracking
    * Concurrent download management
    * Video metadata extraction
    * NixOS integration (uses yt-dlp from nixpkgs)
    * JSON-based communication with yt-dlp

  ## Configuration

  You can configure the application in your `config/config.exs`:

      config :yt_dlp,
        max_concurrent_downloads: 3,
        output_dir: "/custom/path"  # Default: System.tmp_dir!() <> "/yt_dlp"

  ## Usage

  ### Download a video asynchronously

      {:ok, download_id} = YtDlp.download("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      {:ok, status} = YtDlp.get_status(download_id)

  ### Download with custom options

      {:ok, download_id} = YtDlp.download(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        format: "best",
        output_dir: "/tmp/videos"
      )

  ### Get video information without downloading

      {:ok, info} = YtDlp.get_info("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      IO.puts("Title: \#{info["title"]}")

  ### List all downloads

      downloads = YtDlp.list_downloads()
      Enum.each(downloads, fn download ->
        IO.puts("\#{download.url} - \#{download.status}")
      end)

  ### Download and wait for completion

      {:ok, result} = YtDlp.download_sync("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      IO.puts("Downloaded to: \#{result.path}")

  ### Download with real-time progress tracking

      {:ok, download_id} = YtDlp.download(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        progress_callback: fn progress ->
          IO.write("\\rProgress: \#{progress.percent}% at \#{progress.speed}")
        end
      )
  """

  alias YtDlp.Downloader
  alias YtDlp.Error

  @type download_id :: String.t()
  @type download_result :: %{path: String.t(), url: String.t()}
  @type download_info :: Downloader.download_info()

  @doc """
  Downloads a video asynchronously with real-time progress tracking.

  Returns immediately with a download ID that can be used to track the
  download status.

  ## Parameters

    * `url` - Video URL to download
    * `opts` - Download options (optional)
      * `:format` - Video format (default: "best")
      * `:output_dir` - Directory to save the video
      * `:filename_template` - Output filename template
      * `:timeout` - Download timeout in milliseconds
      * `:progress_callback` - Function called with progress updates

  ## Returns

    * `{:ok, download_id}` - Download queued successfully
    * `{:error, reason}` - Failed to queue download

  ## Examples

      # Basic download
      {:ok, download_id} = YtDlp.download("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

      # With custom format and directory
      {:ok, download_id} = YtDlp.download(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        format: "bestvideo+bestaudio",
        output_dir: "/tmp/videos"
      )

      # With progress tracking
      {:ok, download_id} = YtDlp.download(
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        progress_callback: fn progress ->
          IO.write("\\r\#{progress.percent}% - \#{progress.speed} - ETA: \#{progress.eta}")
        end
      )
  """
  @spec download(String.t(), keyword()) :: {:ok, download_id()} | {:error, Error.error()}
  def download(url, opts \\ []) do
    Downloader.download(Downloader, url, opts)
  end

  @doc """
  Downloads a video synchronously and waits for completion.

  Blocks until the download is complete or fails.

  ## Parameters

    * `url` - Video URL to download
    * `opts` - Download options
      * `:poll_interval` - Status check interval in ms (default: 1000)
      * `:max_wait` - Maximum wait time in ms (default: 3600000 - 1 hour)
      * All other options from `download/2`

  ## Returns

    * `{:ok, result}` - Download completed successfully
    * `{:error, reason}` - Download failed

  ## Examples

      {:ok, %{path: path}} = YtDlp.download_sync("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      IO.puts("Downloaded to: \#{path}")
  """
  @spec download_sync(String.t(), keyword()) :: {:ok, download_result()} | {:error, Error.error()}
  def download_sync(url, opts \\ []) do
    poll_interval = Keyword.get(opts, :poll_interval, 1000)
    max_wait = Keyword.get(opts, :max_wait, 3_600_000)
    download_opts = Keyword.drop(opts, [:poll_interval, :max_wait])

    with {:ok, download_id} <- download(url, download_opts) do
      wait_for_completion(download_id, poll_interval, max_wait)
    end
  end

  @doc """
  Gets the status of a download.

  ## Parameters

    * `download_id` - Download ID returned from `download/2`

  ## Returns

    * `{:ok, download_info}` - Download information
    * `{:error, :not_found}` - Download not found

  ## Examples

      {:ok, download_id} = YtDlp.download("https://example.com/video")
      {:ok, status} = YtDlp.get_status(download_id)
      IO.inspect(status.status)  # :pending, :downloading, :completed, or :failed
  """
  @spec get_status(download_id()) :: {:ok, download_info()} | {:error, :not_found}
  def get_status(download_id) do
    Downloader.get_status(Downloader, download_id)
  end

  @doc """
  Lists all downloads.

  Returns a list of all download information, sorted by start time (most recent first).

  ## Examples

      downloads = YtDlp.list_downloads()
      Enum.each(downloads, fn dl ->
        IO.puts("\#{dl.url} - \#{dl.status}")
      end)
  """
  @spec list_downloads() :: [download_info()]
  def list_downloads do
    Downloader.list_downloads(Downloader)
  end

  @doc """
  Cancels a pending download.

  Note: Active downloads cannot currently be cancelled mid-download.

  ## Parameters

    * `download_id` - Download ID to cancel

  ## Returns

    * `:ok` - Download cancelled successfully
    * `{:error, reason}` - Failed to cancel

  ## Examples

      {:ok, download_id} = YtDlp.download("https://example.com/video")
      :ok = YtDlp.cancel(download_id)
  """
  @spec cancel(download_id()) :: :ok | {:error, Error.error()}
  def cancel(download_id) do
    Downloader.cancel(Downloader, download_id)
  end

  @doc """
  Gets video information without downloading.

  Fetches metadata about the video including title, duration, formats, etc.

  ## Parameters

    * `url` - Video URL
    * `opts` - Options (optional)

  ## Returns

    * `{:ok, video_info}` - Map containing video metadata
    * `{:error, reason}` - Failed to get info

  ## Examples

      {:ok, info} = YtDlp.get_info("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
      IO.puts("Title: \#{info["title"]}")
      IO.puts("Duration: \#{info["duration"]} seconds")
      IO.puts("Uploader: \#{info["uploader"]}")
  """
  @spec get_info(String.t(), keyword()) :: {:ok, map()} | {:error, Error.error()}
  def get_info(url, opts \\ []) do
    Downloader.get_info(Downloader, url, opts)
  end

  @doc """
  Checks if yt-dlp is available on the system.

  ## Returns

    * `{:ok, version}` - yt-dlp is available with version string
    * `{:error, reason}` - yt-dlp is not available

  ## Examples

      case YtDlp.check_installation() do
        {:ok, version} -> IO.puts("yt-dlp version: \#{version}")
        {:error, reason} -> IO.puts("yt-dlp not found: \#{reason}")
      end
  """
  @spec check_installation() :: {:ok, String.t()} | {:error, Error.error()}
  def check_installation do
    case YtDlp.Command.run(["--version"]) do
      {:ok, version} -> {:ok, String.trim(version)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Private Functions

  defp wait_for_completion(download_id, poll_interval, max_wait, elapsed \\ 0) do
    if elapsed >= max_wait do
      {:error,
       Error.timeout_error("Download timed out",
         timeout: max_wait,
         operation: :download_sync
       )}
    else
      case get_status(download_id) do
        {:ok, %{status: :completed, result: result}} ->
          {:ok, result}

        {:ok, %{status: :failed, error: error}} ->
          {:error, error}

        {:ok, %{status: _}} ->
          Process.sleep(poll_interval)
          wait_for_completion(download_id, poll_interval, max_wait, elapsed + poll_interval)

        {:error, :not_found} ->
          {:error,
           Error.not_found_error("Download not found",
             resource: :download,
             identifier: download_id
           )}
      end
    end
  end
end

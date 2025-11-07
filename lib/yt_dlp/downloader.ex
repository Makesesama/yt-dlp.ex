defmodule YtDlp.Downloader do
  @moduledoc """
  GenServer that manages video download operations.

  This GenServer provides a high-level interface for downloading videos
  using yt-dlp. It manages concurrent downloads, tracks download status,
  and provides callbacks for progress monitoring.

  ## Features

    * Asynchronous download operations
    * Download status tracking
    * Configurable concurrent download limits
    * Success/error callbacks

  ## Usage

      # Start the downloader (usually done by the application supervisor)
      {:ok, pid} = YtDlp.Downloader.start_link()

      # Request a download
      {:ok, download_id} = YtDlp.Downloader.download(pid, "https://example.com/video")

      # Check download status
      {:ok, status} = YtDlp.Downloader.get_status(pid, download_id)

      # List all downloads
      downloads = YtDlp.Downloader.list_downloads(pid)
  """

  use GenServer
  require Logger

  alias YtDlp.Command

  @type download_id :: String.t()
  @type download_status :: :pending | :downloading | :completed | :failed
  @type download_info :: %{
          id: download_id(),
          url: String.t(),
          status: download_status(),
          result: map() | nil,
          error: String.t() | nil,
          progress: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @type state :: %{
          downloads: %{download_id() => download_info()},
          port_pids: %{download_id() => pid()},
          max_concurrent: pos_integer(),
          active_downloads: non_neg_integer(),
          output_dir: String.t()
        }

  # Client API

  @doc """
  Starts the Downloader GenServer.

  ## Options

    * `:name` - Process name (default: `__MODULE__`)
    * `:max_concurrent` - Maximum concurrent downloads (default: 3)
    * `:output_dir` - Directory to save downloads (default: "./downloads")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Requests a video download.

  ## Parameters

    * `server` - GenServer process identifier
    * `url` - Video URL to download
    * `opts` - Download options
      * `:format` - Video format (default: "best")
      * `:filename_template` - Output filename template
      * `:timeout` - Download timeout in milliseconds

  ## Returns

    * `{:ok, download_id}` - Download queued successfully
    * `{:error, reason}` - Failed to queue download
  """
  @spec download(GenServer.server(), String.t(), keyword()) ::
          {:ok, download_id()} | {:error, String.t()}
  def download(server \\ __MODULE__, url, opts \\ []) do
    GenServer.call(server, {:download, url, opts})
  end

  @doc """
  Gets the status of a specific download.

  ## Returns

    * `{:ok, download_info}` - Download information
    * `{:error, :not_found}` - Download ID not found
  """
  @spec get_status(GenServer.server(), download_id()) ::
          {:ok, download_info()} | {:error, :not_found}
  def get_status(server \\ __MODULE__, download_id) do
    GenServer.call(server, {:get_status, download_id})
  end

  @doc """
  Lists all downloads.

  ## Returns

    List of all download information maps.
  """
  @spec list_downloads(GenServer.server()) :: [download_info()]
  def list_downloads(server \\ __MODULE__) do
    GenServer.call(server, :list_downloads)
  end

  @doc """
  Cancels a pending or downloading video.

  This will stop the yt-dlp process if it's currently downloading.

  ## Returns

    * `:ok` - Download cancelled successfully
    * `{:error, reason}` - Failed to cancel
  """
  @spec cancel(GenServer.server(), download_id()) :: :ok | {:error, String.t()}
  def cancel(server \\ __MODULE__, download_id) do
    GenServer.call(server, {:cancel, download_id})
  end

  @doc """
  Gets information about a video without downloading it.

  ## Returns

    * `{:ok, video_info}` - Video metadata
    * `{:error, reason}` - Failed to get info
  """
  @spec get_info(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def get_info(server \\ __MODULE__, url, opts \\ []) do
    GenServer.call(server, {:get_info, url, opts}, 30_000)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, 3)
    output_dir = Keyword.get(opts, :output_dir, "./downloads")

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    state = %{
      downloads: %{},
      port_pids: %{},
      max_concurrent: max_concurrent,
      active_downloads: 0,
      output_dir: output_dir
    }

    Logger.info("YtDlp.Downloader started with max_concurrent=#{max_concurrent}")

    {:ok, state}
  end

  @impl true
  def handle_call({:download, url, opts}, _from, state) do
    download_id = generate_download_id()

    download_info = %{
      id: download_id,
      url: url,
      status: :pending,
      opts: opts,
      result: nil,
      error: nil,
      progress: nil,
      started_at: nil,
      completed_at: nil
    }

    new_state = put_in(state.downloads[download_id], download_info)

    # Try to start the download immediately if capacity available
    new_state = maybe_start_next_download(new_state)

    {:reply, {:ok, download_id}, new_state}
  end

  @impl true
  def handle_call({:get_status, download_id}, _from, state) do
    case Map.fetch(state.downloads, download_id) do
      {:ok, download_info} ->
        # Remove internal opts and port_pid from the response
        clean_info = Map.drop(download_info, [:opts, :port_pid])
        {:reply, {:ok, clean_info}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_downloads, _from, state) do
    downloads =
      state.downloads
      |> Map.values()
      |> Enum.map(&Map.drop(&1, [:opts, :port_pid]))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    {:reply, downloads, state}
  end

  @impl true
  def handle_call({:cancel, download_id}, _from, state) do
    case Map.fetch(state.downloads, download_id) do
      {:ok, %{status: :pending}} ->
        new_downloads = Map.delete(state.downloads, download_id)
        {:reply, :ok, %{state | downloads: new_downloads}}

      {:ok, %{status: :downloading}} ->
        # Actually cancel the active download using the port PID
        case Map.fetch(state.port_pids, download_id) do
          {:ok, port_pid} ->
            Command.cancel_download(port_pid)

            new_state =
              state
              |> update_download(download_id, %{
                status: :failed,
                error: "Download cancelled by user",
                completed_at: DateTime.utc_now()
              })
              |> Map.update!(:port_pids, &Map.delete(&1, download_id))
              |> Map.update!(:active_downloads, &max(&1 - 1, 0))
              |> maybe_start_next_download()

            {:reply, :ok, new_state}

          :error ->
            {:reply, {:error, "Port PID not found for active download"}, state}
        end

      {:ok, %{status: status}} ->
        {:reply, {:error, "Download already #{status}"}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_info, url, opts}, _from, state) do
    result = Command.get_info(url, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:start_download, download_id}, state) do
    case Map.fetch(state.downloads, download_id) do
      {:ok, download_info} ->
        # Mark as downloading and start async task
        updated_info = %{
          download_info
          | status: :downloading,
            started_at: DateTime.utc_now()
        }

        new_state =
          state
          |> put_in([:downloads, download_id], updated_info)
          |> Map.update!(:active_downloads, &(&1 + 1))

        # Start async download with port
        {:ok, port_pid} = do_download(self(), download_id, download_info, state.output_dir)

        # Store port PID for cancellation
        new_state = put_in(new_state.port_pids[download_id], port_pid)

        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:download_result, _url, {:ok, result}}, state) do
    # Find the download by URL since that's what we get back
    download_id =
      state.downloads
      |> Enum.find(fn {_id, info} -> info.url == result.url end)
      |> case do
        {id, _} -> id
        nil -> nil
      end

    if download_id do
      Logger.info("Download #{download_id} completed successfully")

      new_state =
        state
        |> update_download(download_id, %{
          status: :completed,
          result: result,
          completed_at: DateTime.utc_now()
        })
        |> Map.update!(:port_pids, &Map.delete(&1, download_id))
        |> Map.update!(:active_downloads, &max(&1 - 1, 0))
        |> maybe_start_next_download()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:download_result, url, {:error, error}}, state) do
    # Find the download by URL
    download_id =
      state.downloads
      |> Enum.find(fn {_id, info} -> info.url == url end)
      |> case do
        {id, _} -> id
        nil -> nil
      end

    if download_id do
      Logger.error("Download #{download_id} failed: #{error}")

      new_state =
        state
        |> update_download(download_id, %{
          status: :failed,
          error: error,
          completed_at: DateTime.utc_now()
        })
        |> Map.update!(:port_pids, &Map.delete(&1, download_id))
        |> Map.update!(:active_downloads, &max(&1 - 1, 0))
        |> maybe_start_next_download()

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:download_progress, download_id, progress}, state) do
    new_state = update_download(state, download_id, %{progress: progress})
    {:noreply, new_state}
  end

  # Private Functions

  defp generate_download_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp maybe_start_next_download(state) do
    if state.active_downloads < state.max_concurrent do
      case find_pending_download(state.downloads) do
        {:ok, download_id} ->
          send(self(), {:start_download, download_id})
          state

        :error ->
          state
      end
    else
      state
    end
  end

  defp find_pending_download(downloads) do
    downloads
    |> Enum.find(fn {_id, info} -> info.status == :pending end)
    |> case do
      {id, _info} -> {:ok, id}
      nil -> :error
    end
  end

  defp update_download(state, download_id, updates) do
    case Map.fetch(state.downloads, download_id) do
      {:ok, download_info} ->
        updated_info = Map.merge(download_info, updates)
        put_in(state.downloads[download_id], updated_info)

      :error ->
        state
    end
  end

  defp do_download(server_pid, download_id, download_info, default_output_dir) do
    %{url: url, opts: opts} = download_info

    # Get output directory from opts or use default
    output_dir = Keyword.get(opts, :output_dir, default_output_dir)

    # Wrap progress callback to send updates to GenServer
    progress_callback =
      case Keyword.get(opts, :progress_callback) do
        nil ->
          fn progress ->
            send(server_pid, {:download_progress, download_id, progress})
          end

        user_callback ->
          fn progress ->
            # Send to GenServer
            send(server_pid, {:download_progress, download_id, progress})
            # Also call user callback
            user_callback.(progress)
          end
      end

    # Merge progress callback into opts
    opts_with_progress = Keyword.put(opts, :progress_callback, progress_callback)

    # Start async download (returns port PID)
    Command.download_async(url, output_dir, opts_with_progress, server_pid)
  end
end

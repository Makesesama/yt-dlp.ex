defmodule MyAppWeb.VideoDownloadLive do
  @moduledoc """
  Phoenix LiveView example for real-time video download progress.

  This demonstrates:
  - Real-time progress updates
  - Download cancellation
  - Multiple concurrent downloads
  - S3 upload after download

  Add to your router:

      live "/videos/download", MyAppWeb.VideoDownloadLive
  """

  use Phoenix.LiveView
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to download updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "downloads")
    end

    socket =
      socket
      |> assign(:downloads, [])
      |> assign(:url_input, "")
      |> assign(:format, "best")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-3xl font-bold mb-6">Video Downloader</h1>

      <!-- Download Form -->
      <form phx-submit="start_download" class="mb-8">
        <div class="flex gap-4">
          <input
            type="text"
            name="url"
            value={@url_input}
            placeholder="Enter video URL..."
            class="flex-1 px-4 py-2 border rounded"
            phx-change="update_url"
          />
          <select name="format" class="px-4 py-2 border rounded">
            <option value="best">Best Quality</option>
            <option value="bestvideo+bestaudio">Best Video + Audio</option>
            <option value="bestaudio">Audio Only</option>
            <option value="worst">Lowest Quality</option>
          </select>
          <button type="submit" class="px-6 py-2 bg-blue-500 text-white rounded hover:bg-blue-600">
            Download
          </button>
        </div>
      </form>

      <!-- Active Downloads -->
      <div class="space-y-4">
        <%= for download <- @downloads do %>
          <div class="border rounded-lg p-4 bg-white shadow">
            <!-- Download Header -->
            <div class="flex justify-between items-start mb-2">
              <div class="flex-1">
                <h3 class="font-semibold text-lg"><%= download.title || "Loading..." %></h3>
                <p class="text-sm text-gray-500"><%= download.url %></p>
              </div>
              <div class="flex gap-2">
                <%= if download.status in [:pending, :downloading] do %>
                  <button
                    phx-click="cancel_download"
                    phx-value-id={download.id}
                    class="px-3 py-1 text-sm bg-red-500 text-white rounded hover:bg-red-600"
                  >
                    Cancel
                  </button>
                <% end %>
              </div>
            </div>

            <!-- Status Badge -->
            <div class="mb-3">
              <span class={"px-2 py-1 text-xs rounded #{status_color(download.status)}"}>
                <%= status_text(download.status) %>
              </span>
            </div>

            <!-- Progress Bar -->
            <%= if download.status == :downloading && download.progress do %>
              <div class="mb-2">
                <div class="flex justify-between text-sm text-gray-600 mb-1">
                  <span><%= Float.round(download.progress.percent || 0, 1) %>%</span>
                  <span><%= download.progress.speed || "N/A" %></span>
                  <span>ETA: <%= download.progress.eta || "N/A" %></span>
                </div>
                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-blue-500 h-2 rounded-full transition-all duration-300"
                    style={"width: #{download.progress.percent || 0}%"}
                  >
                  </div>
                </div>
              </div>
            <% end %>

            <!-- Upload Status -->
            <%= if download.upload_status do %>
              <div class="mt-2 text-sm">
                <span class="text-gray-600">S3 Upload:</span>
                <span class={upload_status_color(download.upload_status)}>
                  <%= upload_status_text(download.upload_status) %>
                </span>
              </div>
            <% end %>

            <!-- Result -->
            <%= if download.status == :completed && download.s3_url do %>
              <div class="mt-3 p-2 bg-green-50 rounded">
                <p class="text-sm text-green-800">
                  <strong>S3 URL:</strong>
                  <a href={download.s3_url} target="_blank" class="underline">
                    <%= download.s3_url %>
                  </a>
                </p>
              </div>
            <% end %>

            <!-- Error -->
            <%= if download.status == :failed && download.error do %>
              <div class="mt-3 p-2 bg-red-50 rounded">
                <p class="text-sm text-red-800">
                  <strong>Error:</strong> <%= download.error %>
                </p>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if Enum.empty?(@downloads) do %>
        <div class="text-center text-gray-500 py-12">
          No downloads yet. Enter a video URL above to get started.
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("update_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, :url_input, url)}
  end

  @impl true
  def handle_event("start_download", %{"url" => url, "format" => format}, socket) do
    case YtDlp.download(url,
           format: format,
           progress_callback: &progress_callback/1
         ) do
      {:ok, download_id} ->
        # Add to downloads list
        download = %{
          id: download_id,
          url: url,
          format: format,
          status: :pending,
          progress: nil,
          title: nil,
          error: nil,
          upload_status: nil,
          s3_url: nil
        }

        # Fetch video info in background
        Task.start(fn ->
          case YtDlp.get_info(url) do
            {:ok, info} ->
              Phoenix.PubSub.broadcast(
                MyApp.PubSub,
                "downloads",
                {:download_info, download_id, info["title"]}
              )

            _ ->
              :ok
          end
        end)

        # Monitor download status
        Task.start(fn ->
          monitor_download(download_id, url)
        end)

        socket =
          socket
          |> update(:downloads, fn downloads -> [download | downloads] end)
          |> assign(:url_input, "")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start download: #{reason}")}
    end
  end

  @impl true
  def handle_event("cancel_download", %{"id" => download_id}, socket) do
    case YtDlp.cancel(download_id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Download cancelled")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{reason}")}
    end
  end

  @impl true
  def handle_info({:download_progress, download_id, progress}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | status: :downloading, progress: progress}
          else
            download
          end
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:download_info, download_id, title}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | title: title}
          else
            download
          end
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:download_complete, download_id, file_path}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | status: :completed, upload_status: :uploading}
          else
            download
          end
        end)
      end)

    # Start S3 upload
    Task.start(fn ->
      upload_to_s3(download_id, file_path)
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:download_failed, download_id, error}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | status: :failed, error: error}
          else
            download
          end
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:upload_complete, download_id, s3_url}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | upload_status: :completed, s3_url: s3_url}
          else
            download
          end
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:upload_failed, download_id, error}, socket) do
    socket =
      update(socket, :downloads, fn downloads ->
        Enum.map(downloads, fn download ->
          if download.id == download_id do
            %{download | upload_status: :failed, error: error}
          else
            download
          end
        end)
      end)

    {:noreply, socket}
  end

  # Private Functions

  defp progress_callback(progress) do
    # This could be enhanced to broadcast to PubSub
    # but we're already monitoring via get_status
    :ok
  end

  defp monitor_download(download_id, url) do
    case YtDlp.get_status(download_id) do
      {:ok, %{status: :completed, result: result}} ->
        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "downloads",
          {:download_complete, download_id, result.path}
        )

      {:ok, %{status: :failed, error: error}} ->
        Phoenix.PubSub.broadcast(
          MyApp.PubSub,
          "downloads",
          {:download_failed, download_id, error}
        )

      {:ok, %{status: status, progress: progress}} when status in [:pending, :downloading] ->
        if progress do
          Phoenix.PubSub.broadcast(
            MyApp.PubSub,
            "downloads",
            {:download_progress, download_id, progress}
          )
        end

        Process.sleep(1000)
        monitor_download(download_id, url)

      _ ->
        :ok
    end
  end

  defp upload_to_s3(download_id, file_path) do
    # In a real app, use Waffle:
    # case MyApp.VideoUploader.store({file_path, %{id: download_id}}) do
    #   {:ok, filename} ->
    #     s3_url = MyApp.VideoUploader.url({filename, %{id: download_id}})
    #     Phoenix.PubSub.broadcast(MyApp.PubSub, "downloads", {:upload_complete, download_id, s3_url})
    #   {:error, reason} ->
    #     Phoenix.PubSub.broadcast(MyApp.PubSub, "downloads", {:upload_failed, download_id, reason})
    # end

    # Simulate upload
    Process.sleep(2000)

    s3_url = "https://s3.amazonaws.com/bucket/#{Path.basename(file_path)}"

    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "downloads",
      {:upload_complete, download_id, s3_url}
    )

    # Clean up local file
    File.rm(file_path)
  end

  defp status_color(:pending), do: "bg-yellow-100 text-yellow-800"
  defp status_color(:downloading), do: "bg-blue-100 text-blue-800"
  defp status_color(:completed), do: "bg-green-100 text-green-800"
  defp status_color(:failed), do: "bg-red-100 text-red-800"

  defp status_text(:pending), do: "Pending"
  defp status_text(:downloading), do: "Downloading"
  defp status_text(:completed), do: "Completed"
  defp status_text(:failed), do: "Failed"

  defp upload_status_color(:uploading), do: "text-blue-600"
  defp upload_status_color(:completed), do: "text-green-600"
  defp upload_status_color(:failed), do: "text-red-600"

  defp upload_status_text(:uploading), do: "Uploading..."
  defp upload_status_text(:completed), do: "✓ Uploaded"
  defp upload_status_text(:failed), do: "✗ Upload Failed"
end

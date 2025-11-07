defmodule YtDlp.Application do
  @moduledoc """
  Application supervisor for YtDlp.

  Starts and supervises the Downloader GenServer that manages
  video download operations.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Downloader GenServer
      {YtDlp.Downloader, downloader_opts()}
    ]

    opts = [strategy: :one_for_one, name: YtDlp.Supervisor]

    Logger.info("Starting YtDlp application")

    Supervisor.start_link(children, opts)
  end

  defp downloader_opts do
    [
      name: YtDlp.Downloader,
      max_concurrent: Application.get_env(:yt_dlp, :max_concurrent_downloads, 3),
      output_dir: Application.get_env(:yt_dlp, :output_dir, "./downloads")
    ]
  end
end

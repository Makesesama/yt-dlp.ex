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
      # Start the ProxyManager GenServer (if proxies are configured)
      {YtDlp.ProxyManager, proxy_manager_opts()},
      # Start the Downloader GenServer
      {YtDlp.Downloader, downloader_opts()}
    ]

    opts = [strategy: :one_for_one, name: YtDlp.Supervisor]

    Logger.info("Starting YtDlp application")

    Supervisor.start_link(children, opts)
  end

  defp proxy_manager_opts do
    [
      proxies: Application.get_env(:yt_dlp, :proxies, []),
      strategy: Application.get_env(:yt_dlp, :proxy_rotation_strategy, :round_robin),
      failure_threshold: Application.get_env(:yt_dlp, :proxy_failure_threshold, 3),
      default_timeout: Application.get_env(:yt_dlp, :proxy_default_timeout, 30_000)
    ]
  end

  defp downloader_opts do
    default_output_dir = Path.join(System.tmp_dir!(), "yt_dlp")

    [
      name: YtDlp.Downloader,
      max_concurrent: Application.get_env(:yt_dlp, :max_concurrent_downloads, 3),
      output_dir: Application.get_env(:yt_dlp, :output_dir, default_output_dir)
    ]
  end
end

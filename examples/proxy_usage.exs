#!/usr/bin/env elixir

# Proxy Usage Examples
#
# This script demonstrates how to use the proxy features in yt-dlp.ex
# including proxy lists, rotation strategies, and timeout configuration.

Mix.install([
  {:yt_dlp, path: "."}
])

defmodule ProxyUsageDemo do
  @moduledoc """
  Demonstrates various proxy usage patterns with yt-dlp.ex
  """

  require Logger

  def run do
    IO.puts("""
    ======================================
    YtDlp.ex Proxy Usage Examples
    ======================================
    """)

    # Example 1: Basic proxy usage
    example_basic_proxy()

    # Example 2: Proxy manager with rotation
    example_proxy_manager()

    # Example 3: Proxy health tracking
    example_health_tracking()

    # Example 4: Different rotation strategies
    example_rotation_strategies()

    # Example 5: Per-proxy timeouts
    example_proxy_timeouts()
  end

  defp example_basic_proxy do
    IO.puts("\n--- Example 1: Basic Proxy Usage ---\n")

    # Download with a specific proxy
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    IO.puts("Downloading with specific proxy...")

    case YtDlp.download(url,
           proxy: "http://proxy.example.com:8080",
           output_dir: "/tmp/yt_dlp"
         ) do
      {:ok, download_id} ->
        IO.puts("Download queued with ID: #{download_id}")
        IO.puts("Using proxy: http://proxy.example.com:8080")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp example_proxy_manager do
    IO.puts("\n--- Example 2: Proxy Manager with Rotation ---\n")

    # Configure proxy list in application config
    # In a real application, this would be in config/config.exs:
    #
    # config :yt_dlp,
    #   proxies: [
    #     "http://proxy1.example.com:8080",
    #     "http://proxy2.example.com:8080",
    #     "http://proxy3.example.com:8080"
    #   ],
    #   proxy_rotation_strategy: :round_robin

    # For this example, we'll start ProxyManager manually
    {:ok, _pid} =
      YtDlp.ProxyManager.start_link(
        proxies: [
          "http://proxy1.example.com:8080",
          "http://proxy2.example.com:8080",
          "http://proxy3.example.com:8080"
        ],
        strategy: :round_robin
      )

    IO.puts("Started ProxyManager with 3 proxies")

    # Download using proxy manager (will rotate automatically)
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    case YtDlp.download(url,
           use_proxy_manager: true,
           output_dir: "/tmp/yt_dlp"
         ) do
      {:ok, download_id} ->
        IO.puts("Download queued with ID: #{download_id}")
        IO.puts("Proxy will be automatically rotated on each download")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp example_health_tracking do
    IO.puts("\n--- Example 3: Proxy Health Tracking ---\n")

    # Start ProxyManager with failure threshold
    {:ok, _pid} =
      YtDlp.ProxyManager.start_link(
        proxies: [
          "http://proxy1.example.com:8080",
          "http://proxy2.example.com:8080"
        ],
        strategy: :round_robin,
        failure_threshold: 3
      )

    IO.puts("Proxies will be disabled after 3 consecutive failures")

    # Simulate some downloads and track health
    {:ok, proxy} = YtDlp.ProxyManager.get_proxy()
    IO.puts("Got proxy: #{proxy.url}")

    # Simulate success
    YtDlp.ProxyManager.report_success(proxy.url)
    IO.puts("Reported success for #{proxy.url}")

    # Check statistics
    stats = YtDlp.ProxyManager.get_stats()

    IO.puts("\nProxy Statistics:")

    Enum.each(stats, fn proxy ->
      total = proxy.success_count + proxy.failure_count
      success_rate = if total > 0, do: proxy.success_count / total * 100, else: 0

      IO.puts("""
        URL: #{proxy.url}
        Success: #{proxy.success_count}
        Failures: #{proxy.failure_count}
        Success Rate: #{Float.round(success_rate, 2)}%
        Enabled: #{proxy.enabled}
      """)
    end)
  end

  defp example_rotation_strategies do
    IO.puts("\n--- Example 4: Different Rotation Strategies ---\n")

    proxies = [
      "http://proxy1.example.com:8080",
      "http://proxy2.example.com:8080",
      "http://proxy3.example.com:8080"
    ]

    strategies = [:round_robin, :random, :least_used, :healthiest]

    Enum.each(strategies, fn strategy ->
      IO.puts("\nTesting #{strategy} strategy:")

      {:ok, _pid} =
        YtDlp.ProxyManager.start_link(
          proxies: proxies,
          strategy: strategy
        )

      # Get a few proxies to demonstrate rotation
      for i <- 1..3 do
        {:ok, proxy} = YtDlp.ProxyManager.get_proxy()
        IO.puts("  Request #{i}: #{proxy.url}")
      end

      GenServer.stop(YtDlp.ProxyManager)
    end)
  end

  defp example_proxy_timeouts do
    IO.puts("\n--- Example 5: Per-Proxy Timeouts ---\n")

    # Configure proxies with different timeouts
    {:ok, _pid} =
      YtDlp.ProxyManager.start_link(
        proxies: [
          %{url: "http://fast-proxy.example.com:8080", timeout: 10_000},
          %{url: "http://slow-proxy.example.com:8080", timeout: 60_000},
          %{url: "http://medium-proxy.example.com:8080", timeout: 30_000}
        ],
        strategy: :round_robin
      )

    IO.puts("Configured proxies with different timeouts:")

    stats = YtDlp.ProxyManager.get_stats()

    Enum.each(stats, fn proxy ->
      IO.puts("  #{proxy.url}: #{proxy.timeout}ms timeout")
    end)

    IO.puts("\nEach proxy will use its configured timeout when making requests")
  end

  defp example_complete_workflow do
    IO.puts("\n--- Complete Workflow Example ---\n")

    # 1. Configure proxy list
    proxies = [
      %{url: "http://proxy1.example.com:8080", timeout: 30_000},
      %{url: "http://proxy2.example.com:8080", timeout: 45_000},
      %{url: "socks5://proxy3.example.com:1080", timeout: 60_000}
    ]

    {:ok, _pid} =
      YtDlp.ProxyManager.start_link(
        proxies: proxies,
        strategy: :healthiest,
        failure_threshold: 3
      )

    IO.puts("1. Configured #{length(proxies)} proxies with 'healthiest' strategy")

    # 2. Download multiple videos
    urls = [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://www.youtube.com/watch?v=9bZkp7q19f0",
      "https://www.youtube.com/watch?v=jNQXAC9IVRw"
    ]

    IO.puts("\n2. Queueing #{length(urls)} downloads...")

    download_ids =
      Enum.map(urls, fn url ->
        {:ok, download_id} =
          YtDlp.download(url,
            use_proxy_manager: true,
            output_dir: "/tmp/yt_dlp",
            progress_callback: fn progress ->
              IO.write(
                "\r[#{download_id}] #{progress.percent}% - #{progress.speed} - ETA: #{progress.eta}"
              )
            end
          )

        download_id
      end)

    IO.puts("Queued #{length(download_ids)} downloads")

    # 3. Monitor downloads
    IO.puts("\n3. Monitoring downloads...")

    monitor_downloads(download_ids)

    # 4. Check final proxy statistics
    IO.puts("\n4. Final Proxy Statistics:")

    stats = YtDlp.ProxyManager.get_stats()

    Enum.each(stats, fn proxy ->
      total = proxy.success_count + proxy.failure_count
      success_rate = if total > 0, do: proxy.success_count / total * 100, else: 0

      IO.puts("""
        #{proxy.url}:
          Timeout: #{proxy.timeout}ms
          Requests: #{total}
          Success Rate: #{Float.round(success_rate, 2)}%
          Status: #{if proxy.enabled, do: "Active", else: "Disabled"}
      """)
    end)
  end

  defp monitor_downloads(download_ids) do
    # Check status periodically
    completed =
      Enum.map(download_ids, fn id ->
        case YtDlp.get_status(id) do
          {:ok, status} ->
            IO.puts("  #{id}: #{status.status}")
            status.status == :completed

          {:error, :not_found} ->
            false
        end
      end)

    if Enum.all?(completed) do
      IO.puts("\nAll downloads completed!")
    else
      Process.sleep(1000)
      monitor_downloads(download_ids)
    end
  end
end

# Run the examples
ProxyUsageDemo.run()

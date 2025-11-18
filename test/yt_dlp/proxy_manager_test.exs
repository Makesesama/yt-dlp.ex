defmodule YtDlp.ProxyManagerTest do
  use ExUnit.Case, async: false
  alias YtDlp.ProxyManager

  setup do
    # Stop the existing ProxyManager if running
    case Process.whereis(ProxyManager) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    :ok
  end

  describe "initialization" do
    test "starts with empty proxy list" do
      {:ok, pid} = ProxyManager.start_link(proxies: [])
      assert Process.alive?(pid)
      assert ProxyManager.get_stats() == []
      GenServer.stop(pid)
    end

    test "initializes with string proxy URLs" do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: [
            "http://proxy1.example.com:8080",
            "http://proxy2.example.com:8080"
          ]
        )

      stats = ProxyManager.get_stats()
      assert length(stats) == 2
      assert Enum.all?(stats, &(&1.enabled == true))
      assert Enum.all?(stats, &(&1.success_count == 0))
      assert Enum.all?(stats, &(&1.failure_count == 0))

      GenServer.stop(pid)
    end

    test "initializes with map proxy configurations" do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: [
            %{url: "http://proxy1.example.com:8080", timeout: 10_000},
            %{url: "socks5://proxy2.example.com:1080", timeout: 20_000}
          ]
        )

      stats = ProxyManager.get_stats()
      assert length(stats) == 2

      [proxy1, proxy2] = stats
      assert proxy1.url == "http://proxy1.example.com:8080"
      assert proxy1.timeout == 10_000
      assert proxy2.url == "socks5://proxy2.example.com:1080"
      assert proxy2.timeout == 20_000

      GenServer.stop(pid)
    end
  end

  describe "proxy selection strategies" do
    setup do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: [
            "http://proxy1.example.com:8080",
            "http://proxy2.example.com:8080",
            "http://proxy3.example.com:8080"
          ],
          strategy: :round_robin
        )

      %{pid: pid}
    end

    test "round_robin rotates through proxies", %{pid: pid} do
      {:ok, proxy1} = ProxyManager.get_proxy()
      {:ok, proxy2} = ProxyManager.get_proxy()
      {:ok, proxy3} = ProxyManager.get_proxy()
      {:ok, proxy4} = ProxyManager.get_proxy()

      assert proxy1.url == "http://proxy1.example.com:8080"
      assert proxy2.url == "http://proxy2.example.com:8080"
      assert proxy3.url == "http://proxy3.example.com:8080"
      # Should wrap around
      assert proxy4.url == "http://proxy1.example.com:8080"

      GenServer.stop(pid)
    end

    test "random strategy returns valid proxies", %{pid: pid} do
      ProxyManager.set_strategy(:random)

      # Get multiple proxies and verify they're all valid
      proxies = for _ <- 1..10, do: ProxyManager.get_proxy()

      assert Enum.all?(proxies, fn
               {:ok, proxy} ->
                 proxy.url in [
                   "http://proxy1.example.com:8080",
                   "http://proxy2.example.com:8080",
                   "http://proxy3.example.com:8080"
                 ]

               _ ->
                 false
             end)

      GenServer.stop(pid)
    end

    test "least_used strategy prefers proxies not recently used", %{pid: pid} do
      ProxyManager.set_strategy(:least_used)

      {:ok, proxy1} = ProxyManager.get_proxy()
      # Wait a moment
      Process.sleep(10)
      {:ok, proxy2} = ProxyManager.get_proxy()

      # Should pick different proxies since they haven't been used
      assert proxy1.url != proxy2.url

      GenServer.stop(pid)
    end

    test "healthiest strategy prefers proxies with better success rate", %{pid: pid} do
      ProxyManager.set_strategy(:healthiest)

      # Manually set up different success rates for proxies
      proxy1_url = "http://proxy1.example.com:8080"
      proxy2_url = "http://proxy2.example.com:8080"

      # Give proxy1 a good success rate
      ProxyManager.report_success(proxy1_url)
      ProxyManager.report_success(proxy1_url)

      # Give proxy2 a poor success rate
      ProxyManager.report_failure(proxy2_url)

      # Now healthiest should prefer proxy1
      {:ok, selected} = ProxyManager.get_proxy()
      assert selected.url == proxy1_url

      GenServer.stop(pid)
    end
  end

  describe "health tracking" do
    setup do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: ["http://proxy.example.com:8080"],
          failure_threshold: 3
        )

      %{pid: pid}
    end

    test "tracks successful requests", %{pid: pid} do
      proxy_url = "http://proxy.example.com:8080"

      ProxyManager.report_success(proxy_url)
      ProxyManager.report_success(proxy_url)

      [proxy] = ProxyManager.get_stats()
      assert proxy.success_count == 2
      assert proxy.failure_count == 0
      assert proxy.enabled == true

      GenServer.stop(pid)
    end

    test "tracks failed requests", %{pid: pid} do
      proxy_url = "http://proxy.example.com:8080"

      ProxyManager.report_failure(proxy_url)
      ProxyManager.report_failure(proxy_url)

      [proxy] = ProxyManager.get_stats()
      assert proxy.success_count == 0
      assert proxy.failure_count == 2
      assert proxy.enabled == true

      GenServer.stop(pid)
    end

    test "disables proxy after exceeding failure threshold", %{pid: pid} do
      proxy_url = "http://proxy.example.com:8080"

      # Report 3 failures (matches threshold)
      ProxyManager.report_failure(proxy_url)
      ProxyManager.report_failure(proxy_url)
      ProxyManager.report_failure(proxy_url)

      [proxy] = ProxyManager.get_stats()
      assert proxy.failure_count == 3
      assert proxy.enabled == false

      # Should return no proxies available
      assert ProxyManager.get_proxy() == {:error, :no_proxies}

      GenServer.stop(pid)
    end

    test "can manually enable/disable proxies", %{pid: pid} do
      proxy_url = "http://proxy.example.com:8080"

      # Disable manually
      assert ProxyManager.disable_proxy(proxy_url) == :ok
      [proxy] = ProxyManager.get_stats()
      assert proxy.enabled == false

      # Enable manually
      assert ProxyManager.enable_proxy(proxy_url) == :ok
      [proxy] = ProxyManager.get_stats()
      assert proxy.enabled == true

      GenServer.stop(pid)
    end

    test "returns error when enabling/disabling non-existent proxy", %{pid: pid} do
      assert ProxyManager.enable_proxy("http://nonexistent.example.com:8080") ==
               {:error, :not_found}

      assert ProxyManager.disable_proxy("http://nonexistent.example.com:8080") ==
               {:error, :not_found}

      GenServer.stop(pid)
    end
  end

  describe "statistics" do
    test "resets statistics for all proxies" do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: [
            "http://proxy1.example.com:8080",
            "http://proxy2.example.com:8080"
          ]
        )

      # Generate some stats
      {:ok, proxy1} = ProxyManager.get_proxy()
      ProxyManager.report_success(proxy1.url)
      ProxyManager.report_failure(proxy1.url)

      {:ok, proxy2} = ProxyManager.get_proxy()
      ProxyManager.report_failure(proxy2.url)
      ProxyManager.report_failure(proxy2.url)

      # Reset
      ProxyManager.reset_stats()

      # Verify all counts are zero and all proxies are enabled
      stats = ProxyManager.get_stats()

      assert Enum.all?(stats, fn proxy ->
               proxy.success_count == 0 and
                 proxy.failure_count == 0 and
                 proxy.enabled == true
             end)

      GenServer.stop(pid)
    end
  end

  describe "proxy retrieval" do
    test "returns error when no proxies configured" do
      {:ok, pid} = ProxyManager.start_link(proxies: [])

      assert ProxyManager.get_proxy() == {:error, :no_proxies}

      GenServer.stop(pid)
    end

    test "returns error when all proxies disabled" do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: ["http://proxy.example.com:8080"],
          failure_threshold: 1
        )

      proxy_url = "http://proxy.example.com:8080"
      ProxyManager.report_failure(proxy_url)

      assert ProxyManager.get_proxy() == {:error, :no_proxies}

      GenServer.stop(pid)
    end

    test "can retrieve proxy by URL" do
      {:ok, pid} =
        ProxyManager.start_link(
          proxies: [
            "http://proxy1.example.com:8080",
            "http://proxy2.example.com:8080"
          ]
        )

      {:ok, proxy} = ProxyManager.get_proxy_by_url("http://proxy2.example.com:8080")
      assert proxy.url == "http://proxy2.example.com:8080"

      GenServer.stop(pid)
    end

    test "returns error when proxy URL not found" do
      {:ok, pid} =
        ProxyManager.start_link(proxies: ["http://proxy1.example.com:8080"])

      assert ProxyManager.get_proxy_by_url("http://nonexistent.example.com:8080") ==
               {:error, :not_found}

      GenServer.stop(pid)
    end
  end

  describe "proxy types" do
    test "supports HTTP proxies" do
      {:ok, pid} = ProxyManager.start_link(proxies: ["http://proxy.example.com:8080"])

      {:ok, proxy} = ProxyManager.get_proxy()
      assert String.starts_with?(proxy.url, "http://")

      GenServer.stop(pid)
    end

    test "supports HTTPS proxies" do
      {:ok, pid} = ProxyManager.start_link(proxies: ["https://proxy.example.com:8080"])

      {:ok, proxy} = ProxyManager.get_proxy()
      assert String.starts_with?(proxy.url, "https://")

      GenServer.stop(pid)
    end

    test "supports SOCKS5 proxies" do
      {:ok, pid} = ProxyManager.start_link(proxies: ["socks5://proxy.example.com:1080"])

      {:ok, proxy} = ProxyManager.get_proxy()
      assert String.starts_with?(proxy.url, "socks5://")

      GenServer.stop(pid)
    end
  end
end

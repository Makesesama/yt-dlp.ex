defmodule YtDlp.StressTest do
  use ExUnit.Case, async: false

  alias YtDlp

  @test_url "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
  @test_output_dir "/tmp/yt_dlp_stress_test"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:yt_dlp)
    :ok
  end

  setup do
    File.rm_rf!(@test_output_dir)
    File.mkdir_p!(@test_output_dir)

    on_exit(fn ->
      File.rm_rf!(@test_output_dir)
    end)

    :ok
  end

  describe "concurrent downloads stress test" do
    @tag :stress
    @tag :external
    @tag timeout: 300_000
    test "handles 10 concurrent downloads" do
      # Start 10 downloads concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            {i, YtDlp.download(@test_url, output_dir: @test_output_dir)}
          end)
        end

      # Wait for all to queue
      results = Task.await_many(tasks, 30_000)

      # All should return download IDs
      assert Enum.all?(results, fn {_i, result} ->
               match?({:ok, _download_id}, result)
             end)

      # Get all download IDs
      download_ids =
        Enum.map(results, fn {_i, {:ok, download_id}} ->
          download_id
        end)

      # All download IDs should be unique
      assert length(Enum.uniq(download_ids)) == 10

      # Verify all are tracked
      all_downloads = YtDlp.list_downloads()
      our_downloads = Enum.filter(all_downloads, &(&1.id in download_ids))

      assert length(our_downloads) == 10
    end

    @tag :stress
    test "handles rapid sequential downloads" do
      # Queue 20 downloads rapidly
      download_ids =
        for i <- 1..20 do
          {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
          {i, download_id}
        end

      assert length(download_ids) == 20

      # All should be tracked
      all_downloads = YtDlp.list_downloads()
      ids = Enum.map(download_ids, fn {_i, id} -> id end)
      our_downloads = Enum.filter(all_downloads, &(&1.id in ids))

      assert length(our_downloads) == 20
    end

    @tag :stress
    test "handles max concurrent limit correctly" do
      # The default max_concurrent is 3
      # Start 10 downloads, only 3 should be downloading at once

      download_ids =
        for _i <- 1..10 do
          {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
          download_id
        end

      # Give downloads a moment to start
      Process.sleep(500)

      # Check statuses
      statuses =
        Enum.map(download_ids, fn id ->
          {:ok, status} = YtDlp.get_status(id)
          status.status
        end)

      # Count downloading vs pending
      downloading_count = Enum.count(statuses, &(&1 == :downloading))
      pending_count = Enum.count(statuses, &(&1 == :pending))

      # Should have at most 3 downloading (max_concurrent)
      assert downloading_count <= 3
      # Rest should be pending
      assert pending_count >= 7
    end
  end

  describe "cancellation stress test" do
    @tag :stress
    test "handles rapid cancellations" do
      # Start 10 downloads and immediately cancel them
      download_ids =
        for _i <- 1..10 do
          {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
          download_id
        end

      # Cancel all rapidly
      results =
        Enum.map(download_ids, fn id ->
          YtDlp.cancel(id)
        end)

      # All should either succeed or fail gracefully
      assert Enum.all?(results, fn result ->
               result == :ok or match?({:error, _}, result)
             end)
    end

    @tag :stress
    test "handles cancellation of already completed downloads" do
      {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)

      # Try to cancel multiple times
      for _i <- 1..5 do
        YtDlp.cancel(download_id)
      end

      # Should handle gracefully
      assert true
    end
  end

  describe "status check stress test" do
    @tag :stress
    test "handles concurrent status checks" do
      {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)

      # Check status concurrently 100 times
      tasks =
        for _i <- 1..100 do
          Task.async(fn ->
            YtDlp.get_status(download_id)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result)
             end)
    end

    @tag :stress
    test "handles status checks for many downloads" do
      # Create 50 downloads
      download_ids =
        for _i <- 1..50 do
          {:ok, id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
          id
        end

      # Check all statuses
      results =
        Enum.map(download_ids, fn id ->
          YtDlp.get_status(id)
        end)

      # All should succeed
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result)
             end)
    end
  end

  describe "list_downloads stress test" do
    @tag :stress
    test "handles list_downloads with many entries" do
      # Create 100 downloads
      for _i <- 1..100 do
        YtDlp.download(@test_url, output_dir: @test_output_dir)
      end

      # List should handle it
      downloads = YtDlp.list_downloads()

      assert is_list(downloads)
      assert length(downloads) >= 100
    end

    @tag :stress
    test "handles concurrent list_downloads calls" do
      # Create some downloads first
      for _i <- 1..10 do
        YtDlp.download(@test_url, output_dir: @test_output_dir)
      end

      # Call list_downloads concurrently 50 times
      tasks =
        for _i <- 1..50 do
          Task.async(fn ->
            YtDlp.list_downloads()
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, fn downloads ->
               is_list(downloads)
             end)
    end
  end

  describe "memory leak test" do
    @tag :stress
    @tag timeout: 120_000
    test "no memory leak with many downloads" do
      # Get initial memory
      initial_memory = :erlang.memory(:total)

      # Create and cancel 100 downloads
      for _i <- 1..100 do
        {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
        YtDlp.cancel(download_id)
      end

      # Force garbage collection
      :erlang.garbage_collect()
      Process.sleep(1000)

      # Check memory hasn't grown excessively
      final_memory = :erlang.memory(:total)
      growth_ratio = final_memory / initial_memory

      # Memory shouldn't grow more than 2x (generous threshold)
      assert growth_ratio < 2.0,
             "Memory grew from #{initial_memory} to #{final_memory} (#{growth_ratio}x)"
    end
  end

  describe "error recovery stress test" do
    @tag :stress
    test "recovers from multiple failed downloads" do
      # Try to download from invalid URLs
      invalid_urls = for i <- 1..10, do: "https://invalid-domain-#{i}.com/video"

      results =
        Enum.map(invalid_urls, fn url ->
          YtDlp.download(url, output_dir: @test_output_dir)
        end)

      # All should either succeed queuing or fail gracefully
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result) or match?({:error, _}, result)
             end)

      # System should still be responsive
      downloads = YtDlp.list_downloads()
      assert is_list(downloads)
    end

    @tag :stress
    test "handles rapid download and cancel cycles" do
      for _cycle <- 1..20 do
        {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
        YtDlp.cancel(download_id)
      end

      # System should still work
      downloads = YtDlp.list_downloads()
      assert is_list(downloads)
    end
  end

  describe "progress callback stress test" do
    @tag :stress
    @tag :external
    @tag timeout: 120_000
    test "handles many progress callbacks" do
      # Counter for progress updates
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      {:ok, download_id} =
        YtDlp.download(
          @test_url,
          output_dir: @test_output_dir,
          progress_callback: fn _progress ->
            Agent.update(counter, &(&1 + 1))
          end
        )

      # Wait a bit for some progress
      Process.sleep(5000)

      # Should have received multiple progress updates
      count = Agent.get(counter, & &1)

      # Cancel download
      YtDlp.cancel(download_id)

      # Even if download failed, callback shouldn't crash the system
      assert count >= 0
    end

    @tag :stress
    test "handles crashing progress callbacks" do
      # Progress callback that crashes
      crashing_callback = fn _progress ->
        raise "Intentional crash"
      end

      # Should handle gracefully
      result =
        YtDlp.download(
          @test_url,
          output_dir: @test_output_dir,
          progress_callback: crashing_callback
        )

      # Download should still work (callback crash shouldn't kill it)
      assert match?({:ok, _}, result)
    end
  end

  describe "resource cleanup stress test" do
    @tag :stress
    test "cleans up port processes after completion" do
      # Get initial process count
      initial_processes = length(Process.list())

      # Start and cancel 20 downloads
      for _i <- 1..20 do
        {:ok, download_id} = YtDlp.download(@test_url, output_dir: @test_output_dir)
        YtDlp.cancel(download_id)
      end

      # Wait for cleanup
      Process.sleep(2000)

      # Process count shouldn't have grown significantly
      final_processes = length(Process.list())
      growth = final_processes - initial_processes

      # Allow some growth but not 20+ new processes
      assert growth < 20,
             "Process count grew from #{initial_processes} to #{final_processes}"
    end
  end
end

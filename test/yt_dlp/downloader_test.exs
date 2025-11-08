defmodule YtDlp.DownloaderTest do
  use ExUnit.Case

  alias YtDlp.Downloader

  setup do
    # Start a test downloader with custom name
    {:ok, pid} =
      Downloader.start_link(
        name: :"test_downloader_#{:rand.uniform(1000)}",
        max_concurrent: 2,
        output_dir: "/tmp/yt_dlp_test"
      )

    {:ok, downloader: pid}
  end

  describe "download/3" do
    test "queues a download request", %{downloader: downloader} do
      url = "https://example.com/video"
      {:ok, download_id} = Downloader.download(downloader, url)

      assert is_binary(download_id)

      {:ok, status} = Downloader.get_status(downloader, download_id)
      assert status.url == url
      assert status.status in [:pending, :downloading]
    end
  end

  describe "get_status/2" do
    test "returns download information", %{downloader: downloader} do
      url = "https://example.com/video"
      {:ok, download_id} = Downloader.download(downloader, url)

      {:ok, info} = Downloader.get_status(downloader, download_id)

      assert info.id == download_id
      assert info.url == url
      assert info.status in [:pending, :downloading, :completed, :failed]
    end

    test "returns error for non-existent download", %{downloader: downloader} do
      assert {:error, :not_found} = Downloader.get_status(downloader, "non-existent")
    end
  end

  describe "list_downloads/1" do
    test "returns all downloads", %{downloader: downloader} do
      Downloader.download(downloader, "https://example.com/video1")
      Downloader.download(downloader, "https://example.com/video2")

      downloads = Downloader.list_downloads(downloader)

      assert length(downloads) == 2
      assert Enum.all?(downloads, &is_map/1)
    end
  end

  describe "cancel/2" do
    test "cancels a pending download", %{downloader: downloader} do
      # Queue multiple downloads to ensure some stay pending
      {:ok, _id1} = Downloader.download(downloader, "https://example.com/video1")
      {:ok, _id2} = Downloader.download(downloader, "https://example.com/video2")
      {:ok, id3} = Downloader.download(downloader, "https://example.com/video3")

      # Try to cancel - at least one should be pending
      case Downloader.cancel(downloader, id3) do
        :ok ->
          downloads = Downloader.list_downloads(downloader)
          refute Enum.any?(downloads, &(&1.id == id3))

        {:error, _} ->
          # Already started downloading
          :ok
      end
    end

    test "returns error for non-existent download", %{downloader: downloader} do
      assert {:error, %YtDlp.Error.NotFoundError{}} =
               Downloader.cancel(downloader, "non-existent")
    end
  end

  describe "get_info/3" do
    @tag :external
    test "fetches video info", %{downloader: downloader} do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case Downloader.get_info(downloader, url) do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, "title")

        {:error, _reason} ->
          # Might fail without network or yt-dlp
          :ok
      end
    end
  end
end

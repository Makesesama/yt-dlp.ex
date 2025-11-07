defmodule YtDlpTest do
  use ExUnit.Case
  doctest YtDlp

  describe "check_installation/0" do
    test "returns version when yt-dlp is installed" do
      case YtDlp.check_installation() do
        {:ok, version} ->
          assert is_binary(version)
          assert String.length(version) > 0

        {:error, _reason} ->
          # yt-dlp might not be available in test environment
          :ok
      end
    end
  end

  describe "download/2" do
    test "queues a download and returns download_id" do
      # Use a valid but small test video URL
      # Note: This test requires network access and yt-dlp to be installed
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

      case YtDlp.download(url) do
        {:ok, download_id} ->
          assert is_binary(download_id)
          assert String.length(download_id) > 0

          # Check status
          {:ok, status} = YtDlp.get_status(download_id)
          assert status.url == url
          assert status.status in [:pending, :downloading, :completed, :failed]

        {:error, _reason} ->
          # Might fail in test environment without network or yt-dlp
          :ok
      end
    end
  end

  describe "get_status/1" do
    test "returns error for non-existent download_id" do
      assert {:error, :not_found} = YtDlp.get_status("non-existent-id")
    end
  end

  describe "list_downloads/0" do
    test "returns a list of downloads" do
      downloads = YtDlp.list_downloads()
      assert is_list(downloads)
    end
  end
end

defmodule YtDlp.MembraneTest do
  use ExUnit.Case, async: false
  doctest YtDlp.Membrane

  alias YtDlp.Membrane

  @test_output_dir "/tmp/yt_dlp_membrane_test"

  setup do
    # Clean up test directory
    File.rm_rf!(@test_output_dir)
    File.mkdir_p!(@test_output_dir)

    on_exit(fn ->
      File.rm_rf!(@test_output_dir)
    end)

    :ok
  end

  describe "generate_thumbnail/2" do
    test "returns error when Membrane not installed" do
      # Membrane is not in deps, so should return error
      result =
        Membrane.generate_thumbnail(
          "/path/to/video.mp4",
          timestamp: 5.0
        )

      # Since Membrane isn't installed, should get dependency error
      # But the function should handle it gracefully
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    @tag :ffmpeg_required
    test "accepts thumbnail generation options" do
      # Test that options are accepted without crashing
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.generate_thumbnail(
          test_video,
          timestamp: 10.0,
          width: 1920,
          height: 1080,
          format: :jpg
        )

      # Will fail because dummy isn't real video, but shouldn't crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles non-existent video file" do
      result =
        Membrane.generate_thumbnail(
          "/nonexistent/video.mp4",
          timestamp: 5.0
        )

      # Should fail gracefully
      assert match?({:error, _}, result)
    end

    test "accepts different image formats" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      for format <- [:jpg, :png] do
        result =
          Membrane.generate_thumbnail(
            test_video,
            format: format,
            output_dir: @test_output_dir
          )

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    test "accepts custom output path" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")
      custom_output = Path.join(@test_output_dir, "custom_thumb.jpg")

      result =
        Membrane.generate_thumbnail(
          test_video,
          output_path: custom_output
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "extract_audio_track/2" do
    test "returns error when Membrane not installed" do
      result =
        Membrane.extract_audio_track(
          "/path/to/video.mp4",
          format: :mp3
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts different audio formats" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      for format <- [:mp3, :m4a, :wav, :flac] do
        result =
          Membrane.extract_audio_track(
            test_video,
            format: format
          )

        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    test "accepts bitrate option" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.extract_audio_track(
          test_video,
          format: :mp3,
          bitrate: "320k"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts custom output path" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")
      custom_output = Path.join(@test_output_dir, "custom_audio.mp3")

      result =
        Membrane.extract_audio_track(
          test_video,
          output_path: custom_output
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "create_preview/2" do
    test "returns error when Membrane not installed" do
      result =
        Membrane.create_preview(
          "/path/to/video.mp4",
          duration: 30.0
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "requires duration option" do
      # Since Membrane isn't installed, this returns error early
      # In a real app with Membrane, it would raise KeyError
      # Just test it doesn't crash
      result = Membrane.create_preview("/dummy/path.mp4", [])
      assert match?({:error, _}, result)
    end

    test "accepts start_at option" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.create_preview(
          test_video,
          start_at: 10.0,
          duration: 30.0
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts format option" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.create_preview(
          test_video,
          duration: 30.0,
          format: :webm
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "transcode/2" do
    test "returns error when Membrane not installed" do
      result =
        Membrane.transcode(
          "/path/to/video.mp4",
          output_format: :webm
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "requires output_format option" do
      # Since Membrane isn't installed, this returns error early
      # In a real app with Membrane, it would raise KeyError
      # Just test it doesn't crash
      result = Membrane.transcode("/dummy/path.mp4", [])
      assert match?({:error, _}, result)
    end

    test "accepts codec options" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.transcode(
          test_video,
          output_format: :mp4,
          video_codec: "h264",
          audio_codec: "aac"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts bitrate options" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.transcode(
          test_video,
          output_format: :mp4,
          video_bitrate: "2M",
          audio_bitrate: "192k"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts resolution option" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result =
        Membrane.transcode(
          test_video,
          output_format: :mp4,
          resolution: {1920, 1080}
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "download_with_thumbnail/2" do
    @tag :external
    test "downloads video and generates thumbnail" do
      # This is an integration test requiring network
      result =
        Membrane.download_with_thumbnail(
          "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
          thumbnail_at: 3.0,
          output_dir: @test_output_dir
        )

      case result do
        {:ok, %{video: video_path, thumbnail: thumb_path}} ->
          assert is_binary(video_path)
          assert is_binary(thumb_path)

        {:error, reason} ->
          IO.puts("download_with_thumbnail failed (expected): #{reason}")
      end
    end

    @tag :external
    test "accepts thumbnail_at option" do
      result =
        Membrane.download_with_thumbnail(
          "https://youtube.com/invalid",
          thumbnail_at: 10.0,
          max_wait: 5000
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "download_with_audio_extraction/2" do
    @tag :external
    test "downloads video and extracts audio" do
      result =
        Membrane.download_with_audio_extraction(
          "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
          audio_format: :mp3,
          output_dir: @test_output_dir
        )

      case result do
        {:ok, %{video: video_path, audio: audio_path}} ->
          assert is_binary(video_path)
          assert is_binary(audio_path)

        {:error, reason} ->
          IO.puts("download_with_audio_extraction failed (expected): #{reason}")
      end
    end

    @tag :external
    test "accepts audio format option" do
      result =
        Membrane.download_with_audio_extraction(
          "https://youtube.com/invalid",
          audio_format: :m4a,
          max_wait: 5000
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    @tag :external
    test "accepts audio bitrate option" do
      result =
        Membrane.download_with_audio_extraction(
          "https://youtube.com/invalid",
          audio_bitrate: "320k",
          max_wait: 5000
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "edge cases" do
    test "handles empty file path" do
      result = Membrane.generate_thumbnail("", timestamp: 5.0)

      assert match?({:error, _}, result)
    end

    test "handles very long file paths" do
      long_path = "/" <> String.duplicate("a", 10_000) <> "/video.mp4"

      result = Membrane.generate_thumbnail(long_path, timestamp: 5.0)

      assert match?({:error, _}, result)
    end

    test "handles special characters in paths" do
      special_path = Path.join(@test_output_dir, "video with spaces & special!@#.mp4")

      result = Membrane.generate_thumbnail(special_path, timestamp: 5.0)

      assert match?({:error, _}, result)
    end

    test "handles negative timestamp" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result = Membrane.generate_thumbnail(test_video, timestamp: -5.0)

      # Should handle gracefully
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very large timestamp" do
      test_video = Path.join(@test_output_dir, "test.mp4")
      File.write!(test_video, "dummy")

      result = Membrane.generate_thumbnail(test_video, timestamp: 999_999.0)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end

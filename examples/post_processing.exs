#!/usr/bin/env elixir

# Example: Post-processing videos with ffmpeg and Membrane
# Run with: mix run examples/post_processing.exs

IO.puts("=== Post-Processing Examples ===\n")

# Start the application
{:ok, _} = Application.ensure_all_started(:yt_dlp)

test_url = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

# Example 1: Extract Audio Only
IO.puts("1. Extracting audio as MP3...")

case YtDlp.PostProcessor.extract_audio(test_url,
       format: :mp3,
       quality: "192K",
       output_dir: "/tmp/yt_dlp_audio"
     ) do
  {:ok, audio_path} ->
    IO.puts("   ✓ Audio extracted: #{audio_path}")
    stat = File.stat!(audio_path)
    IO.puts("     File size: #{format_bytes(stat.size)}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 2: Download Best Quality Video + Audio
IO.puts("2. Downloading and merging best video + audio...")

case YtDlp.PostProcessor.download_and_merge(test_url,
       video_format: "bestvideo[height<=1080]",
       audio_format: "bestaudio",
       output_format: :mp4,
       output_dir: "/tmp/yt_dlp_merged"
     ) do
  {:ok, result} ->
    IO.puts("   ✓ Video downloaded and merged: #{result.path}")

    if File.exists?(result.path) do
      stat = File.stat!(result.path)
      IO.puts("     File size: #{format_bytes(stat.size)}")
    end

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 3: Using Format Helpers
IO.puts("3. Using format helpers...")

# Audio only with helper
audio_format = YtDlp.PostProcessor.audio_only(:mp3, "320K")
IO.puts("   Audio-only format string: #{audio_format}")

# Specific video quality helper
video_format = YtDlp.PostProcessor.video_quality(1080)
IO.puts("   1080p format string: #{video_format}")

{:ok, download_id} = YtDlp.download(test_url, format: video_format)
IO.puts("   ✓ Started download with format: #{video_format}")
IO.puts("     Download ID: #{download_id}")

IO.puts("")

# Example 4: Extract Thumbnail
IO.puts("4. Extracting video thumbnail...")

case YtDlp.PostProcessor.extract_thumbnail(test_url,
       format: :jpg,
       output_dir: "/tmp/yt_dlp_thumbs"
     ) do
  {:ok, thumb_path} ->
    IO.puts("   ✓ Thumbnail extracted: #{thumb_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 5: Download with Subtitles
IO.puts("5. Downloading with embedded subtitles...")

case YtDlp.PostProcessor.download_with_subtitles(test_url,
       langs: ["en", "es"],
       auto_subs: true,
       output_dir: "/tmp/yt_dlp_subs"
     ) do
  {:ok, video_path} ->
    IO.puts("   ✓ Video with subtitles: #{video_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 6: Membrane Integration - Generate Thumbnail
IO.puts("6. Membrane integration - Generate thumbnail from video...")

# First download a video
{:ok, result} = YtDlp.download_sync(test_url, output_dir: "/tmp/yt_dlp_membrane")

case YtDlp.Membrane.generate_thumbnail(result.path,
       timestamp: 5.0,
       width: 1280,
       height: 720,
       format: :jpg
     ) do
  {:ok, thumb_path} ->
    IO.puts("   ✓ Thumbnail generated: #{thumb_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
    IO.puts("   Note: Requires ffmpeg to be installed")
end

IO.puts("")

# Example 7: Membrane - Extract Audio Track
IO.puts("7. Membrane integration - Extract audio track...")

case YtDlp.Membrane.extract_audio_track(result.path,
       format: :mp3,
       bitrate: "320k"
     ) do
  {:ok, audio_path} ->
    IO.puts("   ✓ Audio extracted: #{audio_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 8: Membrane - Create Preview Clip
IO.puts("8. Membrane integration - Create preview clip...")

case YtDlp.Membrane.create_preview(result.path,
       start_at: 2.0,
       duration: 10.0
     ) do
  {:ok, preview_path} ->
    IO.puts("   ✓ Preview created: #{preview_path}")
    stat = File.stat!(preview_path)
    IO.puts("     File size: #{format_bytes(stat.size)}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 9: Membrane - Transcode Video
IO.puts("9. Membrane integration - Transcode to different format...")

case YtDlp.Membrane.transcode(result.path,
       output_format: :webm,
       video_codec: "vp9",
       audio_codec: "opus",
       video_bitrate: "1M",
       resolution: {1280, 720}
     ) do
  {:ok, transcoded_path} ->
    IO.puts("   ✓ Video transcoded: #{transcoded_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 10: Complete Pipeline - Download, Process, Upload
IO.puts("10. Complete pipeline - Download → Thumbnail → Audio → Upload...")

defmodule VideoProcessingPipeline do
  def process(url) do
    with {:ok, result} <- YtDlp.download_sync(url, output_dir: "/tmp/pipeline"),
         {:ok, thumb} <- YtDlp.Membrane.generate_thumbnail(result.path, timestamp: 3.0),
         {:ok, audio} <- YtDlp.Membrane.extract_audio_track(result.path, format: :mp3),
         {:ok, preview} <- YtDlp.Membrane.create_preview(result.path, start_at: 0, duration: 15) do
      # Simulate S3 upload
      IO.puts("     [Pipeline] All assets generated:")
      IO.puts("       - Video: #{result.path}")
      IO.puts("       - Thumbnail: #{thumb}")
      IO.puts("       - Audio: #{audio}")
      IO.puts("       - Preview: #{preview}")

      # In production, upload to S3:
      # {:ok, video_url} = MyApp.Uploader.store({result.path, scope})
      # {:ok, thumb_url} = MyApp.Uploader.store({thumb, scope})
      # {:ok, audio_url} = MyApp.Uploader.store({audio, scope})
      # {:ok, preview_url} = MyApp.Uploader.store({preview, scope})

      # Clean up local files
      File.rm(result.path)
      File.rm(thumb)
      File.rm(audio)
      File.rm(preview)

      IO.puts("     [Pipeline] ✓ Cleaned up local files")

      {:ok, :pipeline_complete}
    else
      {:error, reason} ->
        IO.puts("     [Pipeline] ✗ Failed: #{reason}")
        {:error, reason}
    end
  end
end

case VideoProcessingPipeline.process(test_url) do
  {:ok, :pipeline_complete} ->
    IO.puts("   ✓ Pipeline completed successfully!")

  {:error, _} ->
    IO.puts("   ✗ Pipeline failed")
end

IO.puts("")

# Example 11: Convenience Function - Download with Thumbnail
IO.puts("11. Convenience function - Download with auto-generated thumbnail...")

case YtDlp.Membrane.download_with_thumbnail(test_url,
       thumbnail_at: 5.0,
       output_dir: "/tmp/yt_dlp_convenience"
     ) do
  {:ok, %{video: video_path, thumbnail: thumb_path}} ->
    IO.puts("   ✓ Video: #{video_path}")
    IO.puts("   ✓ Thumbnail: #{thumb_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")

# Example 12: Download with Audio Extraction
IO.puts("12. Convenience function - Download with audio extraction...")

case YtDlp.Membrane.download_with_audio_extraction(test_url,
       audio_format: :mp3,
       audio_bitrate: "192k",
       output_dir: "/tmp/yt_dlp_audio_extract"
     ) do
  {:ok, %{video: video_path, audio: audio_path}} ->
    IO.puts("   ✓ Video: #{video_path}")
    IO.puts("   ✓ Audio: #{audio_path}")

  {:error, reason} ->
    IO.puts("   ✗ Failed: #{reason}")
end

IO.puts("")
IO.puts("=== Post-Processing Examples Complete ===")
IO.puts("\nNote: Some features require ffmpeg to be installed.")
IO.puts("Install with: nix-shell -p ffmpeg (or via your package manager)")

# Helper functions

defp format_bytes(bytes) do
  cond do
    bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
    bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
    bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
    true -> "#{bytes} bytes"
  end
end

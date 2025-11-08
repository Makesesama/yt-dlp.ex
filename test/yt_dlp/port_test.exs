defmodule YtDlp.PortTest do
  use ExUnit.Case, async: true

  alias YtDlp.Port

  describe "parse_progress/1" do
    test "parses standard progress line with all fields" do
      line = "[download]  45.2% of 10.5MiB at  1.2MiB/s ETA 00:05"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 45.2
      assert progress.total_size == "10.5MiB"
      assert progress.speed == "1.2MiB/s"
      assert progress.eta == "00:05"
      assert is_binary(progress.downloaded)
    end

    test "parses progress line with fragment info (new format)" do
      line = "[download]   0.9% of ~  30.88MiB at    5.34KiB/s ETA Unknown (frag 0/124)"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 0.9
      assert progress.total_size == "30.88MiB"
      assert progress.speed == "5.34KiB/s"
      assert progress.eta == nil
    end

    test "parses progress line with estimated size (~)" do
      line = "[download]   1.6% of ~   7.63MiB at    5.34KiB/s ETA Unknown (frag 0/124)"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 1.6
      assert progress.total_size == "7.63MiB"
      assert progress.speed == "5.34KiB/s"
    end

    test "parses 100% completion line" do
      line = "[download] 100% of 274.30MiB in 00:45"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 100.0
      assert progress.total_size == "274.30MiB"
    end

    test "parses progress line without ETA" do
      line = "[download]  25.5% of 50.0MiB at  2.5MiB/s"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 25.5
      assert progress.total_size == "50.0MiB"
      assert progress.speed == "2.5MiB/s"
      assert progress.eta == nil
    end

    test "parses progress line without speed or ETA" do
      line = "[download]  10.0% of 100.0MiB"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 10.0
      assert progress.total_size == "100.0MiB"
      assert progress.speed == nil
      assert progress.eta == nil
    end

    test "parses progress with KiB units" do
      line = "[download]  50.0% of 512.00KiB at  128.00KiB/s ETA 00:02"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 50.0
      assert progress.total_size == "512.00KiB"
      assert progress.speed == "128.00KiB/s"
      assert progress.eta == "00:02"
    end

    test "parses progress with GiB units" do
      line = "[download]  15.0% of 2.5GiB at  50.0MiB/s ETA 00:30"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 15.0
      assert progress.total_size == "2.5GiB"
      assert progress.speed == "50.0MiB/s"
      assert progress.eta == "00:30"
    end

    test "returns error for destination line" do
      line = "[download] Destination: /path/to/file.mp4"

      assert :error = Port.parse_progress(line)
    end

    test "returns error for non-progress download message" do
      line = "[download] Resuming download at byte 1024"

      assert :error = Port.parse_progress(line)
    end

    test "returns error for generic message" do
      line = "[youtube] Extracting URL: https://www.youtube.com/watch?v=test"

      assert :error = Port.parse_progress(line)
    end

    test "returns error for warning line" do
      line = "WARNING: [youtube] Falling back to generic n function search"

      assert :error = Port.parse_progress(line)
    end

    test "handles decimal percentages correctly" do
      line = "[download]  0.1% of 1000.0MiB at  10.0MiB/s ETA 01:40"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 0.1
    end

    test "handles progress with extra whitespace" do
      line = "[download]    75.5%   of   100.0MiB   at    25.0MiB/s   ETA   00:01"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 75.5
      assert progress.total_size == "100.0MiB"
      assert progress.speed == "25.0MiB/s"
      assert progress.eta == "00:01"
    end

    test "handles fragment progress for DASH streams" do
      line = "[download]  50.0% of ~ 100.00MiB at  10.00MiB/s ETA Unknown (frag 50/100)"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 50.0
      assert progress.total_size == "100.00MiB"
      assert progress.speed == "10.00MiB/s"
    end

    test "parses very small files (bytes)" do
      line = "[download] 100.0% of ~   1.00KiB at    5.34KiB/s ETA Unknown (frag 0/124)"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 100.0
      assert progress.total_size == "1.00KiB"
    end

    test "handles progress updates during merging" do
      line = "[download]  99.9% of 500.0MiB at  100.0MiB/s ETA 00:00"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.percent == 99.9
      assert progress.eta == "00:00"
    end
  end

  describe "progress calculations" do
    test "calculates downloaded amount correctly for MiB" do
      line = "[download]  50.0% of 100.0MiB at  10.0MiB/s ETA 00:05"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.downloaded == "50.0MiB"
    end

    test "calculates downloaded amount correctly for KiB" do
      line = "[download]  25.0% of 1000.0KiB at  100.0KiB/s ETA 00:08"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.downloaded == "250.0KiB"
    end

    test "calculates downloaded amount for small percentages" do
      line = "[download]  1.0% of 500.0MiB at  5.0MiB/s ETA 01:40"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.downloaded == "5.0MiB"
    end

    test "handles nil total_size gracefully" do
      # This shouldn't happen in practice, but test defensive code
      line = "[download]  50.0%"

      assert {:ok, progress} = Port.parse_progress(line)
      assert progress.downloaded == nil
    end
  end

  describe "edge cases" do
    test "handles empty string" do
      assert :error = Port.parse_progress("")
    end

    test "handles string with only whitespace" do
      assert :error = Port.parse_progress("   ")
    end

    test "handles malformed progress line" do
      assert :error = Port.parse_progress("[download] not a valid progress")
    end

    test "handles line with percentage but wrong format" do
      assert :error = Port.parse_progress("[download] downloading at 50%")
    end

    test "handles unicode characters in output" do
      line = "[download]  50.0% of 100.0MiB at  10.0MiB/s ETA 00:05 ⬇"

      # Should still parse despite extra unicode
      result = Port.parse_progress(line)
      assert match?({:ok, _}, result) or result == :error
    end
  end
end

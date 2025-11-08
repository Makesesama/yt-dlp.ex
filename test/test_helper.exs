# Start the YtDlp application for integration tests
{:ok, _} = Application.ensure_all_started(:yt_dlp)

ExUnit.start()

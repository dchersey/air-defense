# Phase 1 backtest: replay a historic window through the same Predictor and report
# which aircraft would have triggered ANC. Spends credits (historic = 6 cr/flight).
#
#   mix run scripts/backtest.exs              # full window, 60s step
#   STEP=120 mix run scripts/backtest.exs     # coarser/cheaper
#   DRYRUN=1 mix run scripts/backtest.exs     # print plan + cost basis only, no fetches
#
# Window defaults to 2026-05-28 12:00-16:00 UTC. Override (UTC):
#   WINDOW_DATE=2026-05-28 START_UTC=13:00:00 END_UTC=14:00:00 mix run scripts/backtest.exs
edt = fn ts -> DateTime.from_unix!(ts) |> DateTime.add(-4 * 3600) |> DateTime.to_time() |> Time.to_string() end
alias LgaPredictor.{Predictor, FR24.Client}

box = Application.get_env(:lga_predictor, :approach_box)
zone = Application.get_env(:lga_predictor, :noise_zone)
ceiling = Application.get_env(:lga_predictor, :altitude_ceiling_ft)

date = Date.from_iso8601!(System.get_env("WINDOW_DATE", "2026-05-28"))
start_t = Time.from_iso8601!(System.get_env("START_UTC", "12:00:00"))
end_t = Time.from_iso8601!(System.get_env("END_UTC", "16:00:00"))
{:ok, start_dt} = DateTime.new(date, start_t, "Etc/UTC")
{:ok, end_dt} = DateTime.new(date, end_t, "Etc/UTC")
start_ts = DateTime.to_unix(start_dt)
end_ts = DateTime.to_unix(end_dt)
step = String.to_integer(System.get_env("STEP", "60"))
dryrun = System.get_env("DRYRUN") == "1"

now = System.os_time(:second)
oldest_allowed = now - 14 * 86_400
timestamps = Enum.take_every(start_ts..end_ts, step) |> Enum.to_list()

cond do
  start_ts < oldest_allowed ->
    IO.puts("ABORT: window starts #{Float.round((now - start_ts) / 86_400, 1)} days ago — beyond the 14-day historic limit.")
    System.halt(1)

  end_ts > now ->
    IO.puts("ABORT: window is in the future relative to real now (#{DateTime.to_iso8601(DateTime.from_unix!(now))}).")
    System.halt(1)

  true ->
    :ok
end

edt = fn ts -> DateTime.from_unix!(ts) |> DateTime.add(-4 * 3600) |> DateTime.to_time() |> Time.to_string() end
IO.puts("Backtest #{Date.to_string(date)} #{edt.(start_ts)}-#{edt.(end_ts)} EDT (#{Float.round((now - start_ts) / 86_400, 1)} days ago), step #{step}s -> #{length(timestamps)} snapshots, box #{Client.bounds_param(box)}")

if dryrun do
  IO.puts("DRYRUN: would issue #{length(timestamps)} historic queries. Cost = 6 cr * (aircraft returned per snapshot).")
else
  opts = [noise_zone: zone, window_seconds: 120, altitude_ceiling_ft: ceiling]

  throttle = String.to_integer(System.get_env("THROTTLE_MS", "6500"))

  {events, credits} =
    Enum.reduce(timestamps, {[], 0}, fn ts, {events, credits} ->
      Process.sleep(throttle)

      case Client.historic_positions(box, ts, :light, sandbox?: false) do
        {:ok, acs} ->
          windows = Predictor.overflight_windows(acs, opts)
          new = Enum.map(windows, fn w -> {ts, w.aircraft, w} end)
          {events ++ new, credits + length(acs) * 6}

        {:error, reason} ->
          IO.puts("  #{ts}: error #{inspect(reason)}")
          {events, credits}
      end
    end)

  # Group consecutive triggers by aircraft into distinct overflight events.
  by_ac =
    events
    |> Enum.group_by(fn {_ts, ac, _w} -> ac.hex || ac.callsign end)
    |> Enum.map(fn {key, list} ->
      {ts0, ac0, _} = hd(list)
      alts = list |> Enum.map(fn {_, ac, _} -> ac.alt_ft end) |> Enum.filter(&is_number/1)
      first = DateTime.from_unix!(ts0) |> DateTime.add(-4 * 3600) |> DateTime.to_time()
      {key, ac0.callsign, Enum.min(alts, fn -> nil end), length(list), first}
    end)
    |> Enum.sort_by(fn {_, _, _, _, t} -> t end, Time)

  IO.puts("\n=== Predicted overflights (distinct aircraft) ===")
  Enum.each(by_ac, fn {hex, cs, min_alt, hits, t} ->
    IO.puts("  #{Time.to_string(t)} EDT  #{cs || hex}  min_alt=#{min_alt}ft  (#{hits} snapshots)")
  end)

  IO.puts("\nTotal predicted overflights: #{length(by_ac)} aircraft across #{length(events)} trigger-snapshots")
  IO.puts("Snapshots fetched: #{length(timestamps)};  credits spent: ~#{credits}")
end

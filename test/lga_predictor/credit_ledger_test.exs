defmodule LgaPredictor.CreditLedgerTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.CreditLedger

  # Start a ledger with an injectable "current billing period" key (an Agent we
  # can advance) and a unique temp file, so each test is isolated and we can
  # simulate a cycle rollover independent of the real billing day.
  defp start_ledger(period) do
    {:ok, clock} = Agent.start_link(fn -> period end)
    path = Path.join(System.tmp_dir!(), "credits-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, pid} =
      CreditLedger.start_link(
        name: nil,
        path: path,
        period_fun: fn -> Agent.get(clock, & &1) end
      )

    {pid, clock, path}
  end

  defp set_period(clock, period), do: Agent.update(clock, fn _ -> period end)

  # Reserve mode: a finite pool of already-purchased credits (a cancelled
  # subscription's leftovers). These tests exercise the REAL default_period/0 — the
  # injectable period_fun above deliberately bypasses it, and the rollover is exactly
  # what must not happen here.
  defp start_config(credit_mode) do
    path = Path.join(System.tmp_dir!(), "ndcfg_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    start_supervised!({LgaPredictor.ConfigStore, name: LgaPredictor.ConfigStore, path: path})
    {:ok, _} = LgaPredictor.ConfigStore.put(%{"credit_mode" => credit_mode})
    :ok
  end

  defp start_real_ledger do
    path = Path.join(System.tmp_dir!(), "credits-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, pid} = CreditLedger.start_link(name: nil, path: path)
    pid
  end

  test "reserve mode pins the period so the monthly rollover can never fire" do
    start_config("reserve")
    pid = start_real_ledger()

    CreditLedger.seed(pid, 10_000)
    CreditLedger.add(pid, 42)

    assert %{period: "reserve", used: 10_042} = CreditLedger.month_to_date(pid)
  end

  test "monthly mode still keys the period on the billing cycle date" do
    start_config("monthly")
    pid = start_real_ledger()

    assert %{period: period} = CreditLedger.month_to_date(pid)
    assert period =~ ~r/^\d{4}-\d{2}-\d{2}$/, "expected an ISO date, got #{inspect(period)}"
  end

  test "add/2 accumulates credits within a billing period" do
    {pid, _clock, _path} = start_ledger("2026-06-15")

    CreditLedger.add(pid, 6)
    CreditLedger.add(pid, 12)

    assert %{period: "2026-06-15", used: 18} = CreditLedger.month_to_date(pid)
  end

  test "seed/2 sets the absolute used for the period; later adds accumulate on top" do
    {pid, _clock, _path} = start_ledger("2026-06-15")

    CreditLedger.seed(pid, 5_761)
    assert %{used: 5_761} = CreditLedger.month_to_date(pid)

    CreditLedger.add(pid, 6)
    assert %{used: 5_767} = CreditLedger.month_to_date(pid)
  end

  test "rolls over to zero when the billing period changes" do
    {pid, clock, _path} = start_ledger("2026-06-15")

    CreditLedger.add(pid, 100)
    assert %{period: "2026-06-15", used: 100} = CreditLedger.month_to_date(pid)

    set_period(clock, "2026-07-15")
    assert %{period: "2026-07-15", used: 0} = CreditLedger.month_to_date(pid)

    CreditLedger.add(pid, 6)
    assert %{period: "2026-07-15", used: 6} = CreditLedger.month_to_date(pid)
  end

  test "persists across restarts (a redeploy mid-cycle keeps the tally)" do
    {pid, _clock, path} = start_ledger("2026-06-15")
    CreditLedger.seed(pid, 5_761)
    CreditLedger.add(pid, 24)
    assert %{used: 5_785} = CreditLedger.month_to_date(pid)

    # Simulate a restart: a fresh process reading the same file.
    {:ok, clock2} = Agent.start_link(fn -> "2026-06-15" end)
    {:ok, pid2} =
      CreditLedger.start_link(name: nil, path: path, period_fun: fn -> Agent.get(clock2, & &1) end)

    assert %{period: "2026-06-15", used: 5_785} = CreditLedger.month_to_date(pid2)
  end

  describe "cycle_start/2 (billing-anniversary date math)" do
    test "on/after the reset day, the cycle started this month" do
      assert CreditLedger.cycle_start(~D[2026-06-20], 15) == ~D[2026-06-15]
      assert CreditLedger.cycle_start(~D[2026-06-15], 15) == ~D[2026-06-15]
    end

    test "before the reset day, the cycle started last month" do
      assert CreditLedger.cycle_start(~D[2026-06-10], 15) == ~D[2026-05-15]
    end

    test "reset day past the month length clamps to the month's last day" do
      # Feb has no 31st -> clamps to the 28th (2026 is not a leap year).
      assert CreditLedger.cycle_start(~D[2026-02-10], 31) == ~D[2026-01-31]
      assert CreditLedger.cycle_start(~D[2026-03-05], 31) == ~D[2026-02-28]
    end

    test "day 1 reset is the calendar month" do
      assert CreditLedger.cycle_start(~D[2026-06-20], 1) == ~D[2026-06-01]
    end
  end
end

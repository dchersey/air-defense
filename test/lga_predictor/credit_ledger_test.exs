defmodule LgaPredictor.CreditLedgerTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.CreditLedger

  # Start a ledger with an injectable "current month" (an Agent we can advance)
  # and a unique temp file, so each test is isolated and we can simulate rollover.
  defp start_ledger(month) do
    {:ok, clock} = Agent.start_link(fn -> month end)
    path = Path.join(System.tmp_dir!(), "credits-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, pid} =
      CreditLedger.start_link(
        name: nil,
        path: path,
        month_fun: fn -> Agent.get(clock, & &1) end
      )

    {pid, clock, path}
  end

  defp set_month(clock, month), do: Agent.update(clock, fn _ -> month end)

  test "add/2 accumulates credits within a month" do
    {pid, _clock, _path} = start_ledger("2026-06")

    CreditLedger.add(pid, 6)
    CreditLedger.add(pid, 12)

    assert %{month: "2026-06", used: 18} = CreditLedger.month_to_date(pid)
  end

  test "seed/2 sets the absolute used for the month; later adds accumulate on top" do
    {pid, _clock, _path} = start_ledger("2026-06")

    CreditLedger.seed(pid, 5_761)
    assert %{used: 5_761} = CreditLedger.month_to_date(pid)

    CreditLedger.add(pid, 6)
    assert %{used: 5_767} = CreditLedger.month_to_date(pid)
  end

  test "rolls over to zero when the calendar month changes" do
    {pid, clock, _path} = start_ledger("2026-06")

    CreditLedger.add(pid, 100)
    assert %{month: "2026-06", used: 100} = CreditLedger.month_to_date(pid)

    set_month(clock, "2026-07")
    assert %{month: "2026-07", used: 0} = CreditLedger.month_to_date(pid)

    CreditLedger.add(pid, 6)
    assert %{month: "2026-07", used: 6} = CreditLedger.month_to_date(pid)
  end

  test "persists across restarts (a redeploy mid-month keeps the tally)" do
    {pid, _clock, path} = start_ledger("2026-06")
    CreditLedger.seed(pid, 5_761)
    CreditLedger.add(pid, 24)
    assert %{used: 5_785} = CreditLedger.month_to_date(pid)

    # Simulate a restart: a fresh process reading the same file.
    {:ok, clock2} = Agent.start_link(fn -> "2026-06" end)
    {:ok, pid2} =
      CreditLedger.start_link(name: nil, path: path, month_fun: fn -> Agent.get(clock2, & &1) end)

    assert %{month: "2026-06", used: 5_785} = CreditLedger.month_to_date(pid2)
  end
end

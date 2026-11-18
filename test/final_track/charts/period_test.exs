defmodule FinalTrack.Charts.PeriodTest do
  use ExUnit.Case, async: true

  alias FinalTrack.Charts.Period

  test "periods containing a date; weeks start on Monday" do
    date = ~D[2026-11-18]
    assert %{first: ~D[2026-11-18], last: ~D[2026-11-18]} = Period.containing(:day, date)
    assert %{first: ~D[2026-11-16], last: ~D[2026-11-22]} = Period.containing(:week, date)
    assert %{first: ~D[2026-11-01], last: ~D[2026-11-30]} = Period.containing(:month, date)
    assert %{first: ~D[2026-01-01], last: ~D[2026-12-31]} = Period.containing(:year, date)
  end

  test "previous and next cross month and year edges" do
    assert %{first: ~D[2026-02-01], last: ~D[2026-02-28]} =
             Period.containing(:month, ~D[2026-03-15]) |> Period.previous()

    assert %{first: ~D[2027-01-01]} = Period.containing(:year, ~D[2026-06-01]) |> Period.next()

    assert %{first: ~D[2026-12-28], last: ~D[2027-01-03]} =
             Period.containing(:week, ~D[2026-12-31])
  end

  test "buckets: hours of a day, days of a week or month, months of a year" do
    assert {"hour", hours} = Period.buckets(Period.containing(:day, ~D[2026-11-18]))
    assert length(hours) == 24
    assert {"day", days} = Period.buckets(Period.containing(:week, ~D[2026-11-18]))
    assert length(days) == 7
    assert {"day", days} = Period.buckets(Period.containing(:month, ~D[2026-02-10]))
    assert length(days) == 28
    assert {"month", months} = Period.buckets(Period.containing(:year, ~D[2026-02-10]))
    assert length(months) == 12
  end

  test "parse_unit/1 never makes atoms from input" do
    assert Period.parse_unit("month") == :month
    assert Period.parse_unit("fortnight") == :week
    assert Period.parse_unit(nil) == :week
  end
end

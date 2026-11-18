defmodule FinalTrack.Charts.Period do
  @moduledoc """
  A chart's time window: a `unit` (`:day`, `:week`, `:month` or `:year`)
  and the local dates it covers, `first` inclusive to `last` inclusive.
  Weeks start on Monday.

  Periods are calendar dates with no time zone: the viewer's zone is applied
  when querying (see `FinalTrack.Charts`), so "today" is the viewer's today.
  """

  @enforce_keys [:unit, :first, :last]
  defstruct [:unit, :first, :last]

  @type unit :: :day | :week | :month | :year
  @type t :: %__MODULE__{unit: unit(), first: Date.t(), last: Date.t()}

  @units ~w(day week month year)a

  def units, do: @units

  @doc "Parses a unit from a URL param, defaulting to `:week`."
  def parse_unit(unit) when is_binary(unit) do
    Enum.find(@units, :week, &(Atom.to_string(&1) == unit))
  end

  def parse_unit(_), do: :week

  @doc "The period of `unit` that contains `date`."
  @spec containing(unit(), Date.t()) :: t()
  def containing(:day, date), do: new(:day, date, date)

  def containing(:week, date) do
    first = Date.beginning_of_week(date, :monday)
    new(:week, first, Date.add(first, 6))
  end

  def containing(:month, date),
    do: new(:month, Date.beginning_of_month(date), Date.end_of_month(date))

  def containing(:year, date),
    do: new(:year, Date.new!(date.year, 1, 1), Date.new!(date.year, 12, 31))

  defp new(unit, first, last), do: %__MODULE__{unit: unit, first: first, last: last}

  def previous(%__MODULE__{unit: unit, first: first}), do: containing(unit, Date.add(first, -1))
  def next(%__MODULE__{unit: unit, last: last}), do: containing(unit, Date.add(last, 1))

  @doc "Whether `date` falls in the period."
  def contains?(%__MODULE__{first: first, last: last}, date),
    do: Date.compare(date, first) != :lt and Date.compare(date, last) != :gt

  @doc "The local-time bounds, `[from, to)`, as naive datetimes."
  def bounds(%__MODULE__{first: first, last: last}),
    do:
      {NaiveDateTime.new!(first, ~T[00:00:00]),
       NaiveDateTime.new!(Date.add(last, 1), ~T[00:00:00])}

  @doc """
  The bars a timeline of this period is split into: `{step, keys}` where
  `step` is the Postgres `date_trunc` field and each key is the naive start
  of one bar.
  """
  def buckets(%__MODULE__{unit: :day, first: first}) do
    {"hour", for(h <- 0..23, do: NaiveDateTime.new!(first, Time.new!(h, 0, 0)))}
  end

  def buckets(%__MODULE__{unit: :year, first: first}) do
    {"month", for(m <- 1..12, do: NaiveDateTime.new!(Date.new!(first.year, m, 1), ~T[00:00:00]))}
  end

  def buckets(%__MODULE__{first: first, last: last}) do
    {"day", for(d <- Date.range(first, last), do: NaiveDateTime.new!(d, ~T[00:00:00]))}
  end

  @doc "A short label for one timeline bar."
  def bucket_label(%__MODULE__{unit: :day}, %NaiveDateTime{hour: h}),
    do: String.pad_leading(Integer.to_string(h), 2, "0")

  def bucket_label(%__MODULE__{unit: :week}, dt), do: Calendar.strftime(dt, "%a")
  def bucket_label(%__MODULE__{unit: :month}, dt), do: Integer.to_string(dt.day)
  def bucket_label(%__MODULE__{unit: :year}, dt), do: Calendar.strftime(dt, "%b")

  @doc "A human title: \"Tue 18 Nov 2026\", \"Week of 16 Nov 2026\", \"November 2026\", \"2026\"."
  def title(%__MODULE__{unit: :day, first: d}), do: Calendar.strftime(d, "%a %-d %b %Y")
  def title(%__MODULE__{unit: :week, first: d}), do: Calendar.strftime(d, "Week of %-d %b %Y")
  def title(%__MODULE__{unit: :month, first: d}), do: Calendar.strftime(d, "%B %Y")
  def title(%__MODULE__{unit: :year, first: d}), do: Integer.to_string(d.year)
end

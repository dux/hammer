require_relative 'test_helper'

class CronTest < Minitest::Test
  def cron(expr)
    Hammer::Cron.new(expr)
  end

  # -- cron-mode matching ------------------------------------------------

  def test_every_ten_minutes
    c = cron('*/10 * * * *')
    assert c.matches?(Time.local(2026, 7, 10, 12, 0))
    assert c.matches?(Time.local(2026, 7, 10, 12, 50))
    refute c.matches?(Time.local(2026, 7, 10, 12, 5))
  end

  def test_fixed_minute_means_minute_of_each_hour
    c = cron('10 * * * *')
    assert c.matches?(Time.local(2026, 7, 10, 3, 10))
    refute c.matches?(Time.local(2026, 7, 10, 3, 20))
  end

  def test_lists_ranges_and_steps
    c = cron('1,15,45 8-18/2 * * *')
    assert c.matches?(Time.local(2026, 7, 10, 8, 15))
    assert c.matches?(Time.local(2026, 7, 10, 18, 45))
    refute c.matches?(Time.local(2026, 7, 10, 9, 15))   # 9 not in 8-18/2
    refute c.matches?(Time.local(2026, 7, 10, 8, 30))
  end

  def test_weekday_seven_is_sunday
    c = cron('0 0 * * 7')
    assert c.matches?(Time.local(2026, 7, 12, 0, 0))    # a Sunday
    refute c.matches?(Time.local(2026, 7, 13, 0, 0))    # Monday
  end

  # Vixie rule: dom AND dow both restricted -> either matching fires.
  def test_dom_dow_or_rule
    c = cron('0 0 13 * 5')
    assert c.matches?(Time.local(2026, 7, 13, 0, 0))    # 13th (a Monday)
    assert c.matches?(Time.local(2026, 7, 17, 0, 0))    # a Friday, not the 13th
    refute c.matches?(Time.local(2026, 7, 16, 0, 0))    # Thursday the 16th
  end

  def test_dom_restricted_dow_star_requires_dom
    c = cron('0 0 13 * *')
    assert c.matches?(Time.local(2026, 7, 13, 0, 0))
    refute c.matches?(Time.local(2026, 7, 17, 0, 0))
  end

  def test_shortcuts
    assert cron('@hourly').matches?(Time.local(2026, 7, 10, 5, 0))
    assert cron('@daily').matches?(Time.local(2026, 7, 10, 0, 0))
    refute cron('@daily').matches?(Time.local(2026, 7, 10, 1, 0))
    assert cron('@weekly').matches?(Time.local(2026, 7, 12, 0, 0))   # Sunday
    assert cron('@monthly').matches?(Time.local(2026, 7, 1, 0, 0))
  end

  # -- next_run ----------------------------------------------------------

  def test_next_run_simple
    c = cron('*/10 * * * *')
    assert_equal Time.local(2026, 7, 10, 12, 10), c.next_run(Time.local(2026, 7, 10, 12, 3))
    # strictly after `from`, even when `from` itself matches
    assert_equal Time.local(2026, 7, 10, 12, 20), c.next_run(Time.local(2026, 7, 10, 12, 10))
  end

  def test_next_run_crosses_day_and_month
    c = cron('0 3 * * *')
    assert_equal Time.local(2026, 7, 11, 3, 0), c.next_run(Time.local(2026, 7, 10, 4, 0))
    c = cron('30 4 1 * *')
    assert_equal Time.local(2026, 8, 1, 4, 30), c.next_run(Time.local(2026, 7, 10, 12, 0))
  end

  def test_next_run_weekly
    c = cron('0 0 * * 0')
    assert_equal Time.local(2026, 7, 12, 0, 0), c.next_run(Time.local(2026, 7, 10, 12, 0))
  end

  def test_impossible_date_raises
    assert_raises(Hammer::Error) { cron('0 0 30 2 *').next_run(Time.local(2026, 7, 10)) }
  end

  # -- interval mode -----------------------------------------------------

  def test_interval_parsing
    assert_equal 600,    cron('10m').interval
    assert_equal 7200,   cron('2h').interval
    assert_equal 86_400, cron('1d').interval
    assert cron('10m').interval?
    refute cron('* * * * *').interval?
  end

  def test_interval_due
    c    = cron('10m')
    tick = Time.local(2026, 7, 10, 12, 0)
    assert c.due?(tick, nil)                               # never ran -> fire now
    refute c.due?(tick, Time.local(2026, 7, 10, 11, 51))   # 9 min ago
    assert c.due?(tick, Time.local(2026, 7, 10, 11, 50))   # exactly 10 min
  end

  def test_interval_next_run
    c    = cron('90m')
    last = Time.local(2026, 7, 10, 12, 0)
    assert_equal Time.local(2026, 7, 10, 13, 30), c.next_run(Time.local(2026, 7, 10, 12, 5), last_run: last)
    from = Time.local(2026, 7, 10, 12, 5)
    assert_equal from, c.next_run(from, last_run: nil)     # never ran -> now
  end

  # -- due? in cron mode fires once per matching minute --------------------

  def test_cron_due_suppresses_same_minute
    c    = cron('* * * * *')
    tick = Time.local(2026, 7, 10, 12, 0)
    assert c.due?(tick, nil)
    refute c.due?(tick, tick)                              # already fired this minute
    assert c.due?(tick, Time.local(2026, 7, 10, 11, 59))
  end

  # -- validation ----------------------------------------------------------

  def test_invalid_expressions_raise
    [
      '* * * *',        # 4 fields
      '61 * * * *',     # minute out of range
      '* 24 * * *',     # hour out of range
      '*/0 * * * *',    # zero step
      '5-1 * * * *',    # inverted range
      '5/2 * * * *',    # step on bare value
      '@fortnightly',   # unknown shortcut
      '10x',            # bad interval unit
      '0m',             # zero interval
      'abc',
      ''
    ].each do |expr|
      err = assert_raises(Hammer::Error, "expected #{expr.inspect} to raise") { cron(expr) }
      assert_match(/cron/, err.message)
    end
  end

  def test_error_names_the_field
    err = assert_raises(Hammer::Error) { cron('61 * * * *') }
    assert_match(/minute/, err.message)
    err = assert_raises(Hammer::Error) { cron('* * * 13 *') }
    assert_match(/month/, err.message)
  end
end

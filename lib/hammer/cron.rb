class Hammer
  # Schedule of a task declared with `cron '<expr>'`. Parses the
  # expression once (at Hammerfile eval, so typos fail at load time) and
  # answers the scheduler's questions: does this wall-clock minute match,
  # is a run due given the last one, and when is the next run.
  #
  # Accepted forms:
  #
  #   cron '*/10 * * * *'   # standard 5-field crontab
  #   cron '10m'            # simple interval: every 10 minutes
  #   cron '2h'  / '1d'     # every 2 hours / once a day
  #   cron '@daily'         # shortcut, expands to '0 0 * * *'
  #
  # Cron fields support '*', 'a', 'a-b', '*/n', 'a-b/n' and comma lists,
  # numeric values only (no 'jan'/'mon' names). Weekday 7 equals 0
  # (Sunday). Intervals are measured from the last run - not aligned to
  # the clock - which makes odd periods like '90m' possible and keeps
  # restarts from re-firing (last run persists in the state file).
  class Cron
    SHORTCUTS ||= {
      '@hourly'  => '0 * * * *',
      '@daily'   => '0 0 * * *',
      '@weekly'  => '0 0 * * 0',
      '@monthly' => '0 0 1 * *'
    }.freeze

    # [name, min, max] per cron field, in crontab order.
    FIELDS ||= [
      [:minute, 0, 59], [:hour, 0, 23], [:day, 1, 31],
      [:month, 1, 12], [:weekday, 0, 7]
    ].freeze

    INTERVAL_UNITS ||= { 'm' => 60, 'h' => 3600, 'd' => 86_400 }.freeze

    attr_reader :source, :interval

    def initialize(expr)
      @source = expr.to_s.strip

      if (m = @source.match(/\A(\d+)([mhd])\z/))
        @interval = m[1].to_i * INTERVAL_UNITS[m[2]]
        raise Hammer::Error, "cron: interval must be > 0 in #{@source.inspect}" if @interval.zero?
        return
      end

      if @source.start_with?('@') && !SHORTCUTS.key?(@source)
        raise Hammer::Error, "cron: unknown shortcut #{@source.inspect} (valid: #{SHORTCUTS.keys.join(', ')})"
      end

      parts = (SHORTCUTS[@source] || @source).split(/\s+/)
      unless parts.size == 5
        raise Hammer::Error, "cron: #{@source.inspect} - expected 5 fields ('*/10 * * * *'), " \
                             "an interval ('10m', '2h', '1d') or a shortcut (#{SHORTCUTS.keys.join(', ')})"
      end

      @fields   = FIELDS.each_with_index.map { |(name, lo, hi), i| parse_field(name, parts[i], lo, hi) }
      @dom_star = parts[2] == '*'
      @dow_star = parts[4] == '*'
    end

    def interval?
      !@interval.nil?
    end

    # True when local wall-clock time `t` (minute resolution) matches the
    # cron expression. Vixie-cron day rule: when BOTH day-of-month and
    # day-of-week are restricted, matching either one is enough;
    # otherwise both must match.
    def matches?(t)
      return false if interval?
      min, hour, dom, mon, dow = @fields
      return false unless min[t.min] && hour[t.hour] && mon[t.month]
      dom_ok = dom[t.day]
      dow_ok = dow[t.wday]
      @dom_star || @dow_star ? dom_ok && dow_ok : dom_ok || dow_ok
    end

    # Should the scheduler fire at `tick` (a minute-aligned Time), given
    # the persisted last run? Cron mode fires once per matching minute;
    # interval mode fires when a full interval has elapsed (or the job
    # never ran, so a fresh job gives immediate feedback on first tick).
    def due?(tick, last_run)
      if interval?
        last_run.nil? || tick.to_i - last_run.to_i >= @interval
      else
        matches?(tick) && (last_run.nil? || last_run.to_i / 60 < tick.to_i / 60)
      end
    end

    # Next fire time strictly after `from`. Cron mode walks minute by
    # minute - real-world expressions match within days, and the walk is
    # ~100 hash lookups per simulated minute - capped at 500 days so an
    # impossible date (a Feb 30 style expression) fails loudly instead of
    # spinning forever.
    def next_run(from = Time.now, last_run: nil)
      if interval?
        return from if last_run.nil?
        Time.at(last_run.to_i + @interval)
      else
        t = Time.at((from.to_i / 60 + 1) * 60)
        (500 * 24 * 60).times do
          return t if matches?(t)
          t += 60
        end
        raise Hammer::Error, "cron: #{@source.inspect} never matches"
      end
    end

    private

    # Parse one crontab field into a {int => true} lookup hash. Each
    # comma-separated item is '*', 'a', 'a-b', '*/n' or 'a-b/n'.
    # Weekday 7 is folded into 0 - both mean Sunday.
    def parse_field(name, part, lo, hi)
      seen = {}
      part.split(',', -1).each do |item|
        base, step = item.split('/', 2)
        step = step ? parse_int(name, step, 1, hi) : 1
        a, b =
          if base == '*'
            [lo, hi]
          elsif base.include?('-')
            base.split('-', 2).map { |v| parse_int(name, v, lo, hi) }
          elsif item.include?('/')
            raise Hammer::Error, "cron: #{name} - step needs '*' or a range: #{item.inspect}"
          else
            v = parse_int(name, base, lo, hi)
            [v, v]
          end
        raise Hammer::Error, "cron: #{name} - inverted range #{item.inspect}" if a > b
        (a..b).step(step) { |v| seen[name == :weekday && v == 7 ? 0 : v] = true }
      end
      seen
    end

    # Strict integer within [lo, hi], or a Hammer::Error naming the field
    # so the message points straight at the typo.
    def parse_int(name, str, lo, hi)
      v = begin
        Integer(str, 10)
      rescue ArgumentError, TypeError
        nil
      end
      unless v && v.between?(lo, hi)
        raise Hammer::Error, "cron: bad #{name} value #{str.inspect} (allowed #{lo}-#{hi})"
      end
      v
    end
  end
end

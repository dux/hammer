# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'time'

module LlmUsage
  UsageRow = Struct.new(
    :name,
    :session_pct,
    :session_reset,
    :week_pct,
    :week_reset,
    :month_pct,
    :month_reset,
    keyword_init: true
  )

  CACHE_TTL       ||= 180
  CACHE_DIR       ||= File.expand_path('~/.cache/llm')
  GROK_LOG_PATH   ||= File.expand_path('~/.grok/logs/unified.jsonl')
  CODEX_INIT_RPC  ||= '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"llm-usage","version":"1.0"}}}'
  CODEX_LIMITS_RPC ||= '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
  module_function

  def collect_rows(period: nil, providers: nil, now: Time.now, cache: true)
    wanted = normalize_providers(providers)
    rows = []
    notes = []
    label = period_label(period)

    if wanted.include?(:claude)
      data, note = fetch_cached(:claude, cache) { fetch_claude_usage }
      notes << note if note
      notes << 'claude: month billing requires OAuth API (not available locally)' if label == 'month'
      rows.concat(parse_claude(data, now: now)) if data
    end

    if wanted.include?(:codex)
      data, note = fetch_cached(:codex, cache) { fetch_codex_usage }
      notes << note if note
      row = parse_codex(data, now: now)
      rows << row if row
    end

    if wanted.include?(:grok)
      data, note = fetch_cached(:grok, cache) { fetch_grok_usage }
      notes << note if note
      row = parse_grok(data, now: now)
      rows << row if row
    end

    [rows, notes, label]
  end

  def render_table(rows, period: nil)
    return '' if rows.empty?

    headers = table_headers(period)
    widths = column_widths(rows, headers)
    lines = []
    lines << format_row(headers, widths, align: headers.map { :left })
    rows.each do |row|
      lines << format_row(row_cells(row, period), widths)
    end
    lines.join("\n")
  end

  def rows_to_json(rows, period: nil, notes: [])
    {
      period: period_label(period),
      rows: rows.map { |row| row_to_hash(row, period: period) },
      notes: notes
    }
  end

  def format_pct(value)
    return '-' if value.nil?
    "#{value.round}%"
  end

  def format_reset_short(at, now: Time.now)
    target = parse_time(at)
    return '-' unless target

    remaining = (target - now).to_i
    return '-' if remaining <= 0

    days, rem = remaining.divmod(86_400)
    if days >= 1
      hours = rem / 3600
      parts = ["#{days}d"]
      parts << "#{hours}h" if hours.positive?
      return parts.join(' ')
    end

    hours, hour_rem = remaining.divmod(3600)
    if hours >= 1
      mins = hour_rem / 60
      parts = ["#{hours}h"]
      parts << "#{mins}m" if mins.positive?
      return parts.join(' ')
    end

    mins = remaining / 60
    return '-' if mins <= 0

    "#{mins}m"
  end

  def parse_claude(data, now: Time.now)
    return [] unless data.is_a?(Hash)

    five = data['five_hour']
    session_pct = five&.dig('utilization')
    session_reset = five&.dig('resets_at')
    month = claude_month_fields(data['extra_usage'])

    opus = data['seven_day_opus']
    sonnet = data['seven_day_sonnet']
    rows = []

    if opus.is_a?(Hash) || sonnet.is_a?(Hash)
      if opus.is_a?(Hash)
        rows << UsageRow.new(
          name: 'Opus',
          session_pct: format_pct(session_pct),
          session_reset: format_reset_short(session_reset, now: now),
          week_pct: format_pct(opus['utilization']),
          week_reset: format_reset_short(opus['resets_at'], now: now),
          month_pct: month[:pct],
          month_reset: month[:reset]
        )
      end
      if sonnet.is_a?(Hash)
        rows << UsageRow.new(
          name: 'Sonnet',
          session_pct: '-',
          session_reset: '-',
          week_pct: format_pct(sonnet['utilization']),
          week_reset: format_reset_short(sonnet['resets_at'], now: now),
          month_pct: '-',
          month_reset: '-'
        )
      end
      return rows
    end

    week = data['seven_day']
    return [] unless five.is_a?(Hash) || week.is_a?(Hash)

    [
      UsageRow.new(
        name: 'Claude',
        session_pct: format_pct(session_pct),
        session_reset: format_reset_short(session_reset, now: now),
        week_pct: format_pct(week&.dig('utilization')),
        week_reset: format_reset_short(week&.dig('resets_at'), now: now),
        month_pct: month[:pct],
        month_reset: month[:reset]
      )
    ]
  end

  def parse_codex(data, now: Time.now)
    return nil unless data.is_a?(Hash)

    limits = data['rateLimits']
    limits ||= codex_whitelist_to_rate_limits(data) if data['rate_limit']
    return nil unless limits

    primary = limits['primary'] || limits['primary_window']
    secondary = limits['secondary'] || limits['secondary_window']
    session = nil
    week = nil
    [primary, secondary].compact.each do |window|
      mins = window['windowDurationMins'] || (window['limit_window_seconds'].to_i / 60)
      if mins <= 360
        session = window
      elsif mins >= 1440
        week = window
      end
    end
    week ||= primary if primary && !session
    session ||= primary if primary && !week

    UsageRow.new(
      name: 'Codex',
      session_pct: format_pct(window_pct(session)),
      session_reset: format_reset_short(window_reset(session), now: now),
      week_pct: format_pct(window_pct(week)),
      week_reset: format_reset_short(window_reset(week), now: now)
    )
  end

  def parse_grok(data, now: Time.now)
    return nil unless data.is_a?(Hash)

    config = data['config'] || data
    week_pct = config['creditUsagePercent']
    week_reset = config['billingPeriodEnd'] || config.dig('currentPeriod', 'end')
    build = Array(config['productUsage']).find { |p| p['product'] == 'GrokBuild' }

    UsageRow.new(
      name: 'Grok',
      session_pct: '-',
      session_reset: '-',
      week_pct: format_pct(build ? build['usagePercent'] : week_pct),
      week_reset: format_reset_short(week_reset, now: now)
    )
  end

  def fetch_claude_usage
    [nil, 'claude: no local snapshot']
  end

  def fetch_codex_usage
    data, note = codex_app_server_rate_limits
    return [data, note] if data

    data, fallback_note = codex_session_rate_limits
    return [data, fallback_note] if data

    [nil, note || fallback_note || 'codex: no local rate limits']
  end

  def fetch_grok_usage
    grok_log_billing_config
  end

  def codex_app_server_rate_limits
    bin = find_executable('codex')
    return [nil, 'codex: not in PATH'] unless bin

    pipe = Shellwords.shelljoin([bin, 'app-server'])
    cmd = "( printf '%s\\n' #{Shellwords.escape(CODEX_INIT_RPC)}; sleep 0.2; " \
          "printf '%s\\n' #{Shellwords.escape(CODEX_LIMITS_RPC)}; sleep 2 ) | #{pipe}"
    out, status = Open3.capture2('sh', '-c', cmd)
    return [nil, 'codex: app-server rate limits unavailable'] unless status.success?

    limits = nil
    out.each_line do |line|
      msg = JSON.parse(line)
      next unless msg['id'] == 2 && msg['result']

      limits = msg.dig('result', 'rateLimits')
    rescue JSON::ParserError
      next
    end

    return [nil, 'codex: app-server rate limits unavailable'] unless limits.is_a?(Hash)

    [{ 'rateLimits' => limits }, nil]
  rescue Errno::ENOENT
    [nil, 'codex: not in PATH']
  rescue StandardError => e
    [nil, "codex: #{e.message}"]
  end

  def codex_session_rate_limits
    pattern = File.expand_path('~/.codex/sessions/**/rollout-*.jsonl')
    files = Dir.glob(pattern)
    return [nil, nil] if files.empty?

    newest = files.max_by { |f| File.mtime(f) }
    limits = nil
    File.foreach(newest) do |line|
      next if line.strip.empty?

      data = JSON.parse(line)
      next unless data.dig('payload', 'type') == 'token_count'

      rl = data.dig('payload', 'rate_limits')
      limits = rl if rl.is_a?(Hash)
    rescue JSON::ParserError
      next
    end
    return [nil, nil] unless limits

    mapped = {
      'rateLimits' => {
        'primary' => map_codex_session_window(limits['primary']),
        'secondary' => map_codex_session_window(limits['secondary'])
      }
    }
    date = File.mtime(newest).strftime('%b %-d')
    [mapped, "codex: from session log (#{date}, may be stale)"]
  end

  def grok_log_billing_config
    return [nil, 'grok: no billing log (run grok once)'] unless File.file?(GROK_LOG_PATH)

    entry = reverse_find_jsonl(GROK_LOG_PATH) { |obj| obj['msg'] == 'billing: fetched credits config' }
    return [nil, 'grok: no billing log (run grok once)'] unless entry

    config = entry.dig('ctx', 'config')
    return [nil, 'grok: billing log missing config'] unless config.is_a?(Hash)

    note = grok_staleness_note(entry['ts'], now: Time.now)
    [{ 'config' => config }, note]
  end

  def reverse_find_jsonl(path)
    File.readlines(path).reverse_each do |line|
      next if line.strip.empty?

      obj = JSON.parse(line)
      return obj if yield(obj)
    rescue JSON::ParserError
      next
    end
    nil
  end

  def grok_staleness_note(ts, now: Time.now)
    return nil unless ts

    logged_at = Time.parse(ts)
    age = now - logged_at
    return nil if age < 3600

    format_age_note('grok: billing log from', age)
  rescue ArgumentError
    nil
  end

  def format_age_note(prefix, seconds)
    if seconds >= 86_400
      days = (seconds / 86_400).to_i
      "#{prefix} #{days}d ago"
    elsif seconds >= 3600
      hours = (seconds / 3600).to_i
      "#{prefix} #{hours}h ago"
    else
      mins = (seconds / 60).to_i
      "#{prefix} #{mins}m ago"
    end
  end

  def find_executable(cmd)
    path, status = Open3.capture2('sh', '-c', "command -v #{cmd}")
    path = path.strip
    return nil unless status.success? && !path.empty? && File.executable?(path)

    path
  end

  def fetch_cached(provider, use_cache)
    return yield unless use_cache

    path = cache_path(provider)
    if File.file?(path)
      age = Time.now - File.mtime(path)
      if age < CACHE_TTL
        payload = read_json(path)
        return [payload['data'], payload['note']] if payload && payload.key?('data')
      end
    end

    data, note = yield
    if data
      FileUtils.mkdir_p(CACHE_DIR)
      File.write(path, JSON.generate('fetched_at' => Time.now.iso8601, 'data' => data, 'note' => note))
    end
    [data, note]
  end

  def cache_path(provider)
    File.join(CACHE_DIR, "usage-#{provider}.json")
  end

  def normalize_providers(providers)
    list = Array(providers).map(&:to_s).map(&:downcase).reject(&:empty?)
    return %i[claude codex grok] if list.empty?

    valid = %w[claude codex grok]
    bad = list - valid
    raise Hammer::Error, "unknown provider(s): #{bad.join(', ')} (valid: #{valid.join(', ')})" unless bad.empty?

    list.map(&:to_sym)
  end

  def period_label(period)
    case period.to_s.downcase
    when '', 'default', 'session', 'week' then 'default'
    when 'month' then 'month'
    else
      raise Hammer::Error, "unknown period: #{period} (valid: week, month)"
    end
  end

  def table_headers(period)
    if period_label(period) == 'month'
      %w[Name month\ util month\ reset]
    else
      %w[Name session\ util session\ reset week\ util week\ reset]
    end
  end

  def row_cells(row, period)
    if period_label(period) == 'month'
      [row.name, row.month_pct || '-', row.month_reset || '-']
    else
      [row.name, row.session_pct, row.session_reset, row.week_pct, row.week_reset]
    end
  end

  def row_to_hash(row, period: nil)
    if period_label(period) == 'month'
      { name: row.name, month_util: row.month_pct, month_reset: row.month_reset }
    else
      {
        name: row.name,
        session_util: row.session_pct,
        session_reset: row.session_reset,
        week_util: row.week_pct,
        week_reset: row.week_reset
      }
    end
  end

  def column_widths(rows, headers)
    cells = [headers] + rows.map { |row| row_cells(row, nil) }
    headers.each_index.map do |i|
      cells.map { |line| line[i].to_s.length }.max
    end
  end

  def format_row(cells, widths, align: nil)
    align ||= [:left] + [:right] * (cells.length - 1)
    cells.each_with_index.map do |cell, i|
      text = cell.to_s
      if align[i] == :right
        text.rjust(widths[i])
      else
        text.ljust(widths[i])
      end
    end.join('  ')
  end

  def parse_time(at)
    case at
    when nil then nil
    when Numeric then Time.at(at.to_i)
    when String
      return Time.at(at.to_i) if at.match?(/\A\d+\z/)
      Time.parse(at)
    else
      nil
    end
  rescue ArgumentError
    nil
  end

  def window_pct(window)
    return nil unless window.is_a?(Hash)
    window['usedPercent'] || window['used_percent']
  end

  def window_reset(window)
    return nil unless window.is_a?(Hash)
    window['resetsAt'] || window['reset_at']
  end

  def map_codex_window(window)
    return nil unless window.is_a?(Hash)
    {
      'used_percent' => window['used_percent'],
      'limit_window_seconds' => window['limit_window_seconds'],
      'reset_at' => window['reset_at']
    }
  end

  def map_codex_session_window(window)
    return nil unless window.is_a?(Hash)
    {
      'used_percent' => window['used_percent'],
      'windowDurationMins' => window['window_minutes'],
      'resetsAt' => window['resets_at']
    }
  end

  def claude_month_fields(extra)
    return { pct: '-', reset: '-' } unless extra.is_a?(Hash) && extra['is_enabled']

    {
      pct: format_pct(extra['utilization']),
      reset: '-'
    }
  end

  def codex_whitelist_to_rate_limits(data)
    {
      'primary' => map_codex_window(data.dig('rate_limit', 'primary_window')),
      'secondary' => map_codex_window(data.dig('rate_limit', 'secondary_window'))
    }
  end

  def read_json(path)
    return nil unless path && File.file?(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end
end
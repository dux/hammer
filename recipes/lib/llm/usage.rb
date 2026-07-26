# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'shellwords'
require 'time'
require 'uri'

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
  TokenRow = Struct.new(
    :provider,
    :model,
    :day_tokens,
    :week_tokens,
    :month_tokens,
    keyword_init: true
  )

  CACHE_TTL       ||= 180
  CACHE_DIR       ||= File.expand_path('~/.cache/llm')
  GROK_LOG_PATH   ||= File.expand_path('~/.grok/logs/unified.jsonl')
  GROK_SESSION_GLOB ||= File.expand_path('~/.grok/sessions/**/signals.json')
  GROK_SUMMARY_GLOB ||= File.expand_path('~/.grok/sessions/**/summary.json')
  CLAUDE_SESSION_GLOB ||= File.expand_path('~/.claude/projects/**/*.jsonl')
  # Written by the statusline hook (~/.claude/statusline-command.sh) from its
  # `rate_limits` input; mtime is the observation time.
  CLAUDE_LIMITS_PATH ||= File.expand_path('~/.cache/llm/claude-limits.json')
  # Live fallback + the only source of `extra_usage` (the month view).
  CLAUDE_USAGE_URL ||= 'https://api.anthropic.com/api/oauth/usage'
  CLAUDE_OAUTH_BETA ||= 'oauth-2025-04-20'
  CLAUDE_KEYCHAIN_SERVICE ||= 'Claude Code-credentials'
  CLAUDE_CREDENTIALS_PATH ||= File.expand_path('~/.claude/.credentials.json')
  CODEX_SESSION_GLOB ||= File.expand_path('~/.codex/sessions/**/rollout-*.jsonl')
  CODEX_INIT_RPC  ||= '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"llm-usage","version":"1.0"}}}'
  CODEX_LIMITS_RPC ||= '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
  module_function

  def collect_rows(period: nil, providers: nil, now: Time.now, cache: true)
    wanted = normalize_providers(providers)
    rows = []
    notes = []
    label = period_label(period)

    if wanted.include?(:claude)
      # The snapshot path is deliberately uncached: it's one small local file,
      # and caching would freeze the staleness note. Only the API call caches.
      data, note = fetch_claude_usage(period: label, cache: cache, now: now)
      notes << note unless note.nil? || note.empty?
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
    widths = column_widths(rows, headers, period: period)
    lines = []
    lines << format_row(headers, widths, align: headers.map { :left })
    rows.each do |row|
      lines << format_row(row_cells(row, period), widths)
    end
    lines.join("\n")
  end

  def render_token_table(rows)
    return '' if rows.empty?

    headers = ['Provider', 'Model', 'day (mil)', 'week (mil)', 'month (mil)']
    cells = rows.map do |row|
      [
        row.provider,
        row.model,
        format_tokens(row.day_tokens),
        format_tokens(row.week_tokens),
        format_tokens(row.month_tokens)
      ]
    end
    totals = rows.each_with_object(day: 0, week: 0, month: 0) do |row, sum|
      sum[:day] += row.day_tokens.to_i
      sum[:week] += row.week_tokens.to_i
      sum[:month] += row.month_tokens.to_i
    end
    total = [
      'Total',
      '',
      format_tokens(totals[:day]),
      format_tokens(totals[:week]),
      format_tokens(totals[:month])
    ]
    widths = cell_widths([headers] + cells + [total])
    lines = [format_row(headers, widths, align: headers.map { :left })]
    alignment = [:left, :left, :right, :right, :right]
    cells.each { |line| lines << format_row(line, widths, align: alignment) }
    lines << (' ' * (widths[0] + widths[1] + 4)) + ('-' * (widths[2..].sum + 4))
    lines << format_row(total, widths, align: alignment)
    lines.join("\n")
  end

  def rows_to_json(rows, period: nil, notes: [], token_rows: [])
    {
      period: period_label(period),
      rows: rows.map { |row| row_to_hash(row, period: period) },
      token_usage: token_rows.map { |row| token_row_to_hash(row) },
      notes: notes
    }
  end

  def collect_token_rows(providers: nil, now: Time.now)
    wanted = normalize_providers(providers)
    rows = []
    rows.concat(aggregate_claude_tokens(now: now)) if wanted.include?(:claude)
    rows.concat(aggregate_codex_tokens(now: now)) if wanted.include?(:codex)
    rows.concat(aggregate_grok_tokens(now: now)) if wanted.include?(:grok)
    rows.sort_by { |row| [row.provider, row.model] }
  end

  def aggregate_codex_tokens(paths: nil, now: Time.now)
    totals = token_totals
    starts = calendar_period_starts(now)
    session_paths(paths || Dir.glob(CODEX_SESSION_GLOB)).each do |path|
      model = nil
      File.foreach(path) do |line|
        data = JSON.parse(line)
        payload = data['payload'] || {}
        model = payload['model'] if data['type'] == 'turn_context' && payload['model']
        next unless payload['type'] == 'token_count' && model

        usage = payload.dig('info', 'last_token_usage')
        add_token_total(totals, model, data['timestamp'], usage&.dig('total_tokens'), starts, now)
      rescue JSON::ParserError
        next
      end
    end
    build_token_rows('codex', totals)
  end

  def aggregate_claude_tokens(paths: nil, now: Time.now)
    entries = {}
    session_paths(paths || Dir.glob(CLAUDE_SESSION_GLOB)).each do |path|
      File.foreach(path) do |line|
        data = JSON.parse(line)
        message = data['message'] || {}
        usage = message['usage']
        model = message['model']
        next unless usage.is_a?(Hash) && model && model != '<synthetic>'

        total = claude_token_total(usage)
        key = message['id'] || data['uuid'] || [path, data['timestamp'], total]
        current = entries[key]
        if !current || total > current[:total]
          entries[key] = { model: model, at: data['timestamp'], total: total }
        end
      rescue JSON::ParserError
        next
      end
    end

    totals = token_totals
    starts = calendar_period_starts(now)
    entries.each_value do |entry|
      add_token_total(totals, entry[:model], entry[:at], entry[:total], starts, now)
    end
    build_token_rows('claude', totals)
  end

  # Sum actual API tokens from unified.jsonl inference events.
  # Session signals.json only stores current context size (snapshot), not
  # cumulative usage — that undercounted by an order of magnitude.
  def aggregate_grok_tokens(log_path: nil, model_map: nil, now: Time.now)
    path = log_path || GROK_LOG_PATH
    return [] unless File.file?(path)

    totals = token_totals
    starts = calendar_period_starts(now)
    sid_models = model_map || grok_session_model_map

    File.foreach(path) do |line|
      data = JSON.parse(line)
      next unless data['msg'] == 'shell.turn.inference_done'

      ctx = data['ctx'] || {}
      tokens = ctx['prompt_tokens'].to_i + ctx['completion_tokens'].to_i
      next unless tokens.positive?

      model = sid_models[data['sid']] || 'unknown'
      add_token_total(totals, model, data['ts'], tokens, starts, now)
    rescue JSON::ParserError
      next
    end
    build_token_rows('grok', totals)
  end

  def grok_session_model_map(paths: nil)
    map = {}
    # Prefer signals.json; fall back to summary.json (active sessions often
    # write summary before signals).
    files = if paths
              session_paths(paths)
            else
              session_paths(Dir.glob(GROK_SESSION_GLOB) + Dir.glob(GROK_SUMMARY_GLOB))
            end

    files.each do |path|
      data = read_json(path) || {}
      model = if File.basename(path) == 'signals.json'
                summary = read_json(File.join(File.dirname(path), 'summary.json')) || {}
                data['primaryModelId'] || summary['current_model_id']
              else
                data['current_model_id'] || data['primaryModelId']
              end
      next unless model

      sid = File.basename(File.dirname(path))
      # signals win over summary if both exist
      next if map.key?(sid) && File.basename(path) == 'summary.json'

      map[sid] = model
    end
    map
  end

  def format_pct(value)
    return '-' if value.nil?
    "#{value.round}%"
  end

  def format_tokens(value)
    whole, fraction = format('%.1f', value.to_i / 1_000_000.0).split('.')
    grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, '\1_').reverse
    "#{grouped}.#{fraction}"
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

  # The statusline snapshot carries five_hour/seven_day but no `extra_usage`,
  # so the month view has to go to the OAuth API. The default view prefers the
  # snapshot (instant, offline, no token) and only calls out when it's absent.
  def fetch_claude_usage(period: 'default', cache: true, now: Time.now, path: CLAUDE_LIMITS_PATH)
    return fetch_cached(:claude, cache) { fetch_claude_oauth_usage } if period == 'month'

    data, note = fetch_claude_snapshot(now: now, path: path)
    return [data, note] if data

    api_data, api_note = fetch_cached(:claude, cache) { fetch_claude_oauth_usage }
    return [api_data, api_note] if api_data

    [nil, [note, api_note].compact.join('; ')]
  end

  def fetch_claude_snapshot(now: Time.now, path: CLAUDE_LIMITS_PATH)
    snapshot = read_json(path)
    return [nil, 'claude: no local snapshot (statusline writer not installed)'] unless snapshot.is_a?(Hash)

    data = normalize_claude_limits(snapshot, now: now)
    return [nil, 'claude: snapshot has no live windows'] if data.empty?

    age = now - File.mtime(path)
    note = age >= 300 ? format_age_note('claude: snapshot from', age) : nil
    [data, note]
  end

  # Same payload Claude Code's own /usage reads: five_hour, seven_day,
  # seven_day_opus/_sonnet and extra_usage, already in parse_claude's shape.
  def fetch_claude_oauth_usage(now: Time.now)
    token = claude_oauth_token(now: now)
    return [nil, 'claude: no usable OAuth token (run `claude` to sign in or refresh)'] unless token

    uri = URI(CLAUDE_USAGE_URL)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) do |http|
      http.get(uri.request_uri, 'Authorization' => "Bearer #{token}", 'anthropic-beta' => CLAUDE_OAUTH_BETA)
    end
    return [nil, "claude: usage API returned #{response.code}"] unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    return [nil, 'claude: usage API returned no windows'] unless data.is_a?(Hash)

    [data, nil]
  rescue JSON::ParserError
    [nil, 'claude: usage API returned malformed JSON']
  rescue StandardError => e
    [nil, "claude: usage API unreachable (#{e.message})"]
  end

  # Credentials file (Linux) first, then the macOS keychain. An expired token
  # is treated as absent rather than refreshed here — that's Claude Code's job,
  # and refreshing behind its back would invalidate its copy.
  def claude_oauth_token(now: Time.now, path: CLAUDE_CREDENTIALS_PATH)
    creds = read_json(path) || claude_keychain_credentials
    oauth = creds.is_a?(Hash) ? creds['claudeAiOauth'] : nil
    return nil unless oauth.is_a?(Hash)

    token = oauth['accessToken']
    return nil if token.nil? || token.empty?

    expires_at = oauth['expiresAt']
    return nil if expires_at && Time.at(expires_at.to_i / 1000) <= now

    token
  end

  def claude_keychain_credentials
    out, status = Open3.capture2('security', 'find-generic-password', '-s', CLAUDE_KEYCHAIN_SERVICE, '-w')
    return nil unless status.success?

    JSON.parse(out)
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  # Statusline `rate_limits` -> the shape parse_claude reads. Windows whose
  # reset time has already passed are dropped: the window rolled over, so the
  # recorded percentage no longer describes anything.
  def normalize_claude_limits(snapshot, now: Time.now)
    return {} unless snapshot.is_a?(Hash)

    %w[five_hour seven_day seven_day_opus seven_day_sonnet].each_with_object({}) do |key, out|
      window = snapshot[key]
      next unless window.is_a?(Hash)

      resets_at = parse_time(window['resets_at'])
      next if resets_at.nil? || resets_at <= now

      out[key] = {
        'utilization' => window['used_percentage'] || window['utilization'],
        'resets_at' => window['resets_at']
      }
    end
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
      %w[Name month\ utilization month\ reset]
    else
      %w[Name session\ utilization session\ reset week\ utilization week\ reset]
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
      # Mirror row_cells: providers with no month window render '-', not null.
      { name: row.name, month_util: row.month_pct || '-', month_reset: row.month_reset || '-' }
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

  def column_widths(rows, headers, period: nil)
    cell_widths([headers] + rows.map { |row| row_cells(row, period) })
  end

  def cell_widths(cells)
    cells.first.each_index.map { |i| cells.map { |line| line[i].to_s.length }.max }
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

  def calendar_period_starts(now)
    day_date = Date.new(now.year, now.month, now.day)
    week_date = day_date - ((day_date.wday + 6) % 7)
    month_date = Date.new(now.year, now.month, 1)
    {
      day: calendar_midnight(day_date, now),
      week: calendar_midnight(week_date, now),
      month: calendar_midnight(month_date, now)
    }
  end

  def calendar_midnight(date, now)
    if now.utc?
      Time.utc(date.year, date.month, date.day)
    else
      Time.new(date.year, date.month, date.day, 0, 0, 0, now.utc_offset)
    end
  end

  def session_paths(paths)
    Array(paths).reject { |path| File.basename(path).include?('.tmp.') }
  end

  def token_totals
    Hash.new { |hash, model| hash[model] = { day: 0, week: 0, month: 0 } }
  end

  def add_token_total(totals, model, at, value, starts, now)
    timestamp = parse_time(at)
    count = value.to_i
    return unless timestamp && timestamp <= now && count.positive?

    totals[model][:month] += count if timestamp >= starts[:month]
    totals[model][:week] += count if timestamp >= starts[:week]
    totals[model][:day] += count if timestamp >= starts[:day]
  end

  def build_token_rows(provider, totals)
    totals.map do |model, periods|
      TokenRow.new(
        provider: provider,
        model: model,
        day_tokens: periods[:day],
        week_tokens: periods[:week],
        month_tokens: periods[:month]
      )
    end.sort_by(&:model)
  end

  def claude_token_total(usage)
    %w[input_tokens cache_creation_input_tokens cache_read_input_tokens output_tokens].sum do |key|
      usage[key].to_i
    end
  end

  def token_row_to_hash(row)
    {
      provider: row.provider,
      model: row.model,
      day_tokens: row.day_tokens,
      week_tokens: row.week_tokens,
      month_tokens: row.month_tokens
    }
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

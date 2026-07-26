# frozen_string_literal: true

require 'fileutils'
require 'minitest/mock'
require 'tempfile'

require_relative 'test_helper'
require_relative '../recipes/lib/llm/usage'

class LlmUsageTest < Minitest::Test
  NOW = Time.utc(2026, 7, 12, 12, 0, 0)

  def test_format_reset_short_days_hours
    at = NOW + (4 * 86_400) + (3 * 3600)
    assert_equal '4d 3h', LlmUsage.format_reset_short(at.iso8601, now: NOW)
  end

  def test_format_reset_short_days_omit_zero_hours
    at = NOW + (7 * 86_400)
    assert_equal '7d', LlmUsage.format_reset_short(at.iso8601, now: NOW)
  end

  def test_format_reset_short_hours_minutes
    at = NOW + (2 * 3600) + (14 * 60)
    assert_equal '2h 14m', LlmUsage.format_reset_short(at.iso8601, now: NOW)
  end

  def test_format_reset_short_single_hour
    at = NOW + 3600 + (3 * 60)
    assert_equal '1h 3m', LlmUsage.format_reset_short(at.iso8601, now: NOW)
  end

  def test_format_reset_short_sub_hour
    at = NOW + (45 * 60)
    assert_equal '45m', LlmUsage.format_reset_short(at.iso8601, now: NOW)
  end

  def test_format_reset_short_past_returns_dash
    assert_equal '-', LlmUsage.format_reset_short((NOW - 60).iso8601, now: NOW)
  end

  def test_parse_claude_opus_and_sonnet_rows
    data = {
      'five_hour' => { 'utilization' => 33.0, 'resets_at' => (NOW + 8040).iso8601 },
      'seven_day_opus' => { 'utilization' => 13.0, 'resets_at' => (NOW + 356_400).iso8601 },
      'seven_day_sonnet' => { 'utilization' => 1.0, 'resets_at' => (NOW + 334_800).iso8601 }
    }

    rows = LlmUsage.parse_claude(data, now: NOW)
    assert_equal 2, rows.length
    assert_equal 'Opus', rows[0].name
    assert_equal '33%', rows[0].session_pct
    assert_equal '2h 14m', rows[0].session_reset
    assert_equal '13%', rows[0].week_pct
    assert_equal '4d 3h', rows[0].week_reset

    assert_equal 'Sonnet', rows[1].name
    assert_equal '-', rows[1].session_pct
    assert_equal '-', rows[1].session_reset
    assert_equal '1%', rows[1].week_pct
  end

  def test_parse_codex_maps_session_and_week_windows
    data = {
      'rateLimits' => {
        'primary' => { 'used_percent' => 82, 'windowDurationMins' => 300, 'resetsAt' => NOW.to_i + 3780 },
        'secondary' => { 'used_percent' => 36, 'windowDurationMins' => 10_080, 'resetsAt' => NOW.to_i + 216_000 }
      }
    }

    row = LlmUsage.parse_codex(data, now: NOW)
    assert_equal 'Codex', row.name
    assert_equal '82%', row.session_pct
    assert_equal '1h 3m', row.session_reset
    assert_equal '36%', row.week_pct
    assert_equal '2d 12h', row.week_reset
  end

  def test_parse_grok_week_only_session_columns_dash
    data = {
      'config' => {
        'creditUsagePercent' => 4.0,
        'billingPeriodEnd' => (NOW + 598_800).iso8601,
        'productUsage' => [
          { 'product' => 'GrokBuild', 'usagePercent' => 4.0 }
        ]
      }
    }

    row = LlmUsage.parse_grok(data, now: NOW)
    assert_equal 'Grok', row.name
    assert_equal '-', row.session_pct
    assert_equal '-', row.session_reset
    assert_equal '4%', row.week_pct
    assert_equal '6d 22h', row.week_reset
  end

  def test_render_table_default_columns
    rows = [
      LlmUsage::UsageRow.new(
        name: 'Codex',
        session_pct: '82%',
        session_reset: '1h 3m',
        week_pct: '36%',
        week_reset: '2d 12h'
      )
    ]

    table = LlmUsage.render_table(rows)
    assert_includes table, 'Name'
    assert_includes table, 'session utilization'
    assert_includes table, 'session reset'
    assert_includes table, 'week utilization'
    assert_includes table, 'week reset'
    assert_includes table, 'Codex'
    assert_includes table, '82%'
  end

  def test_render_table_month_uses_full_utilization_header
    rows = [
      LlmUsage::UsageRow.new(
        name: 'Claude',
        month_pct: '12%',
        month_reset: '-'
      )
    ]

    table = LlmUsage.render_table(rows, period: 'month')
    assert_includes table, 'month utilization'
  end

  def test_codex_tokens_are_grouped_by_model_and_calendar_period
    events = [
      codex_token_event(Time.utc(2026, 7, 12, 10), 'gpt-5.4', 100),
      codex_token_event(Time.utc(2026, 7, 10, 10), 'gpt-5.4', 200),
      codex_token_event(Time.utc(2026, 7, 2, 10), 'gpt-5.4', 300),
      codex_token_event(Time.utc(2026, 6, 30, 10), 'gpt-5.4', 400)
    ]

    with_jsonl(events) do |path|
      rows = LlmUsage.aggregate_codex_tokens(paths: [path], now: NOW)

      assert_equal 1, rows.length
      assert_equal 'codex', rows[0].provider
      assert_equal 'gpt-5.4', rows[0].model
      assert_equal 100, rows[0].day_tokens
      assert_equal 300, rows[0].week_tokens
      assert_equal 600, rows[0].month_tokens
    end
  end

  def test_claude_tokens_include_cached_input_and_group_by_model
    events = [
      claude_token_event(Time.utc(2026, 7, 12, 10), 'claude-opus-4-8', 10, 20, 30, 40),
      claude_token_event(Time.utc(2026, 7, 8, 10), 'claude-opus-4-8', 1, 2, 3, 4),
      claude_token_event(Time.utc(2026, 7, 2, 10), 'claude-sonnet-4-6', 5, 6, 7, 8)
    ]

    with_jsonl(events) do |path|
      rows = LlmUsage.aggregate_claude_tokens(paths: [path], now: NOW)

      opus = rows.find { |row| row.model == 'claude-opus-4-8' }
      sonnet = rows.find { |row| row.model == 'claude-sonnet-4-6' }
      assert_equal 100, opus.day_tokens
      assert_equal 110, opus.week_tokens
      assert_equal 110, opus.month_tokens
      assert_equal 0, sonnet.day_tokens
      assert_equal 0, sonnet.week_tokens
      assert_equal 26, sonnet.month_tokens
    end
  end

  def test_grok_tokens_are_summed_from_inference_done_log
    events = [
      grok_inference_event(Time.utc(2026, 7, 12, 10), 'sid-a', 100, 20),
      grok_inference_event(Time.utc(2026, 7, 8, 10), 'sid-a', 200, 30),
      grok_inference_event(Time.utc(2026, 7, 2, 10), 'sid-b', 300, 40),
      grok_inference_event(Time.utc(2026, 6, 30, 10), 'sid-a', 999, 1),
      # ignore unrelated log lines
      { 'ts' => Time.utc(2026, 7, 12, 11).iso8601, 'msg' => 'prompt received', 'sid' => 'sid-a' }.to_json
    ]

    model_map = { 'sid-a' => 'grok-4.5', 'sid-b' => 'grok-composer-2.5-fast' }

    with_jsonl(events) do |path|
      rows = LlmUsage.aggregate_grok_tokens(log_path: path, model_map: model_map, now: NOW)

      by_model = rows.to_h { |row| [row.model, row] }
      assert_equal %w[grok-4.5 grok-composer-2.5-fast], by_model.keys.sort

      main = by_model['grok-4.5']
      assert_equal 'grok', main.provider
      assert_equal 120, main.day_tokens
      assert_equal 350, main.week_tokens
      assert_equal 350, main.month_tokens

      composer = by_model['grok-composer-2.5-fast']
      assert_equal 0, composer.day_tokens
      assert_equal 0, composer.week_tokens
      assert_equal 340, composer.month_tokens
    end
  end

  def test_grok_session_model_map_reads_primary_model
    Dir.mktmpdir do |dir|
      path = grok_signal_file(dir, 'abc-session', Time.utc(2026, 7, 12, 10), 0, 0)
      map = LlmUsage.grok_session_model_map(paths: [path])
      assert_equal({ 'abc-session' => 'grok-composer-2.5-fast' }, map)
    end
  end

  def test_grok_session_model_map_reads_summary_when_no_signals
    Dir.mktmpdir do |dir|
      session = File.join(dir, 'live-session')
      FileUtils.mkdir_p(session)
      path = File.join(session, 'summary.json')
      File.write(path, JSON.generate('current_model_id' => 'grok-4.5'))
      map = LlmUsage.grok_session_model_map(paths: [path])
      assert_equal({ 'live-session' => 'grok-4.5' }, map)
    end
  end

  def test_render_token_table_has_day_week_and_month_per_model
    rows = [
      LlmUsage::TokenRow.new(
        provider: 'codex',
        model: 'gpt-5.4',
        day_tokens: 1_234,
        week_tokens: 23_456,
        month_tokens: 345_678
      )
    ]

    table = LlmUsage.render_token_table(rows)
    assert_includes table, 'Provider'
    assert_includes table, 'Model'
    assert_includes table, 'day (mil)'
    assert_includes table, 'week (mil)'
    assert_includes table, 'month (mil)'
    assert_includes table, '0.0'
    assert_includes table, '0.3'
  end

  def test_render_token_table_sums_each_numeric_column
    rows = [
      LlmUsage::TokenRow.new(
        provider: 'claude', model: 'claude-opus',
        day_tokens: 1_000_000, week_tokens: 2_000_000, month_tokens: 3_000_000
      ),
      LlmUsage::TokenRow.new(
        provider: 'codex', model: 'gpt-5.6',
        day_tokens: 1_332_000_000, week_tokens: 4_000_000, month_tokens: 5_000_000
      )
    ]

    lines = LlmUsage.render_token_table(rows).lines.map(&:chomp)
    numeric_start = lines.first.index('day (mil)')
    separator = (' ' * numeric_start) + ('-' * (lines.first.length - numeric_start))

    assert_equal separator, lines[-2]
    assert_match(/\ATotal\s+1_333\.0\s+6\.0\s+8\.0\z/, lines.last)
  end

  def test_format_tokens_rounds_to_one_decimal_million
    assert_equal '222.3', LlmUsage.format_tokens(222_345_678)
    assert_equal '1_333.0', LlmUsage.format_tokens(1_333_000_000)
  end

  def test_rows_to_json_includes_token_usage
    token_rows = [
      LlmUsage::TokenRow.new(
        provider: 'codex', model: 'gpt-5.4',
        day_tokens: 10, week_tokens: 20, month_tokens: 30
      )
    ]

    data = LlmUsage.rows_to_json([], token_rows: token_rows)
    assert_equal 10, data[:token_usage][0][:day_tokens]
    assert_equal 'gpt-5.4', data[:token_usage][0][:model]
  end

  def test_fetch_claude_snapshot_without_file_returns_note
    Dir.mktmpdir do |dir|
      data, note = LlmUsage.fetch_claude_snapshot(now: NOW, path: File.join(dir, 'missing.json'))
      assert_nil data
      assert_equal 'claude: no local snapshot (statusline writer not installed)', note
    end
  end

  def test_fetch_claude_snapshot_reads_file_and_reports_age
    with_claude_snapshot(statusline_rate_limits, age: 7200) do |path|
      data, note = LlmUsage.fetch_claude_snapshot(now: NOW, path: path)
      assert_equal 23.5, data.dig('five_hour', 'utilization')
      assert_equal 'claude: snapshot from 2h ago', note
    end
  end

  def test_fetch_claude_snapshot_omits_note_when_fresh
    with_claude_snapshot(statusline_rate_limits, age: 60) do |path|
      _data, note = LlmUsage.fetch_claude_snapshot(now: NOW, path: path)
      assert_nil note
    end
  end

  def test_fetch_claude_snapshot_with_only_expired_windows_returns_note
    expired = { 'five_hour' => { 'used_percentage' => 90, 'resets_at' => (NOW - 60).to_i } }
    with_claude_snapshot(expired) do |path|
      data, note = LlmUsage.fetch_claude_snapshot(now: NOW, path: path)
      assert_nil data
      assert_equal 'claude: snapshot has no live windows', note
    end
  end

  def test_fetch_claude_usage_prefers_snapshot_over_api
    with_claude_snapshot(statusline_rate_limits, age: 60) do |path|
      LlmUsage.stub(:fetch_claude_oauth_usage, [{ 'five_hour' => { 'utilization' => 99.0 } }, nil]) do
        data, = LlmUsage.fetch_claude_usage(now: NOW, path: path, cache: false)
        assert_equal 23.5, data.dig('five_hour', 'utilization')
      end
    end
  end

  def test_fetch_claude_usage_falls_back_to_api_without_snapshot
    Dir.mktmpdir do |dir|
      LlmUsage.stub(:fetch_claude_oauth_usage, [oauth_usage_payload, nil]) do
        data, note = LlmUsage.fetch_claude_usage(
          now: NOW, path: File.join(dir, 'missing.json'), cache: false
        )
        assert_equal 12.0, data.dig('five_hour', 'utilization')
        assert_nil note
      end
    end
  end

  def test_fetch_claude_usage_reports_both_failures
    Dir.mktmpdir do |dir|
      LlmUsage.stub(:fetch_claude_oauth_usage, [nil, 'claude: usage API returned 401']) do
        data, note = LlmUsage.fetch_claude_usage(
          now: NOW, path: File.join(dir, 'missing.json'), cache: false
        )
        assert_nil data
        assert_includes note, 'no local snapshot'
        assert_includes note, 'usage API returned 401'
      end
    end
  end

  # The month view needs extra_usage, which the statusline never carries — it
  # must go to the API even when a perfectly good snapshot exists.
  def test_fetch_claude_usage_month_ignores_snapshot
    with_claude_snapshot(statusline_rate_limits, age: 60) do |path|
      LlmUsage.stub(:fetch_claude_oauth_usage, [oauth_usage_payload, nil]) do
        data, = LlmUsage.fetch_claude_usage(period: 'month', now: NOW, path: path, cache: false)
        assert_equal true, data.dig('extra_usage', 'is_enabled')
      end
    end
  end

  def test_month_view_renders_claude_extra_usage
    rows = LlmUsage.parse_claude(oauth_usage_payload, now: NOW)
    assert_equal '18%', rows[0].month_pct
    assert_includes LlmUsage.render_table(rows, period: 'month'), 'Claude'
  end

  def test_claude_oauth_token_reads_credentials_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'credentials.json')
      File.write(path, { 'claudeAiOauth' => { 'accessToken' => 'tok', 'expiresAt' => (NOW + 3600).to_i * 1000 } }.to_json)

      assert_equal 'tok', LlmUsage.claude_oauth_token(now: NOW, path: path)
    end
  end

  def test_claude_oauth_token_rejects_expired_token
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'credentials.json')
      File.write(path, { 'claudeAiOauth' => { 'accessToken' => 'tok', 'expiresAt' => (NOW - 1).to_i * 1000 } }.to_json)

      assert_nil LlmUsage.claude_oauth_token(now: NOW, path: path)
    end
  end

  def test_normalize_claude_limits_maps_used_percentage
    data = LlmUsage.normalize_claude_limits(statusline_rate_limits, now: NOW)

    assert_equal %w[five_hour seven_day], data.keys
    assert_equal 23.5, data['five_hour']['utilization']
    assert_equal((NOW + 8040).to_i, data['five_hour']['resets_at'])
    assert_equal 41.2, data['seven_day']['utilization']
  end

  def test_normalize_claude_limits_drops_expired_and_malformed_windows
    snapshot = statusline_rate_limits.merge(
      'five_hour' => { 'used_percentage' => 90, 'resets_at' => (NOW - 1).to_i },
      'seven_day_opus' => 'nonsense'
    )

    assert_equal %w[seven_day], LlmUsage.normalize_claude_limits(snapshot, now: NOW).keys
    assert_empty LlmUsage.normalize_claude_limits({}, now: NOW)
    assert_empty LlmUsage.normalize_claude_limits(nil, now: NOW)
  end

  def test_normalized_snapshot_renders_a_claude_row
    rows = LlmUsage.parse_claude(LlmUsage.normalize_claude_limits(statusline_rate_limits, now: NOW), now: NOW)

    assert_equal 1, rows.length
    assert_equal 'Claude', rows[0].name
    assert_equal '24%', rows[0].session_pct
    assert_equal '2h 14m', rows[0].session_reset
    assert_equal '41%', rows[0].week_pct
    assert_equal '4d 3h', rows[0].week_reset
  end

  def test_grok_log_line_parses_billing
    line = {
      'ts' => (NOW - 7200).iso8601,
      'msg' => 'billing: fetched credits config',
      'ctx' => {
        'config' => {
          'creditUsagePercent' => 12.0,
          'billingPeriodEnd' => (NOW + 598_800).iso8601
        }
      }
    }.to_json

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'unified.jsonl')
      File.write(path, "#{line}\n")

      entry = LlmUsage.reverse_find_jsonl(path) { |obj| obj['msg'] == 'billing: fetched credits config' }
      row = LlmUsage.parse_grok({ 'config' => entry.dig('ctx', 'config') }, now: NOW)
      note = LlmUsage.grok_staleness_note(entry['ts'], now: NOW)

      assert_equal 'Grok', row.name
      assert_equal '-', row.session_pct
      assert_equal '-', row.session_reset
      assert_equal '12%', row.week_pct
      assert_equal '6d 22h', row.week_reset
      assert_equal 'grok: billing log from 2h ago', note
    end
  end

  def test_codex_session_jsonl_extracts_rate_limits
    jsonl = <<~JSONL
      {"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":82,"window_minutes":300,"resets_at":#{NOW.to_i + 3780}},"secondary":{"used_percent":36,"window_minutes":10080,"resets_at":#{NOW.to_i + 216_000}}}}}
    JSONL

    Dir.mktmpdir do |dir|
      sessions = File.join(dir, 'sessions', '2026', '07', '11')
      FileUtils.mkdir_p(sessions)
      path = File.join(sessions, 'rollout-test.jsonl')
      File.write(path, jsonl)

      limits = nil
      File.foreach(path) do |line|
        data = JSON.parse(line)
        limits = data.dig('payload', 'rate_limits') if data.dig('payload', 'type') == 'token_count'
      end

      mapped = {
        'rateLimits' => {
          'primary' => LlmUsage.map_codex_session_window(limits['primary']),
          'secondary' => LlmUsage.map_codex_session_window(limits['secondary'])
        }
      }
      row = LlmUsage.parse_codex(mapped, now: NOW)

      assert_equal '82%', row.session_pct
      assert_equal '1h 3m', row.session_reset
      assert_equal '36%', row.week_pct
      assert_equal '2d 12h', row.week_reset
    end
  end

  def test_normalize_providers_rejects_unknown
    err = assert_raises(Hammer::Error) { LlmUsage.normalize_providers(['claude', 'openai']) }
    assert_includes err.message, 'unknown provider'
  end

  private

  def with_jsonl(events)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'usage.jsonl')
      File.write(path, events.join("\n") + "\n")
      yield path
    end
  end

  def codex_token_event(at, model, total)
    [
      { timestamp: at.iso8601, type: 'turn_context', payload: { model: model } },
      {
        timestamp: at.iso8601,
        type: 'event_msg',
        payload: {
          type: 'token_count',
          info: { last_token_usage: { total_tokens: total } }
        }
      }
    ].map(&:to_json).join("\n")
  end

  def claude_token_event(at, model, input, cache_creation, cache_read, output)
    {
      timestamp: at.iso8601,
      type: 'assistant',
      uuid: "#{model}-#{at.to_i}",
      message: {
        model: model,
        usage: {
          input_tokens: input,
          cache_creation_input_tokens: cache_creation,
          cache_read_input_tokens: cache_read,
          output_tokens: output
        }
      }
    }.to_json
  end

  # Shape of the statusline hook's `rate_limits` object: percentages 0-100 and
  # epoch-second resets, unlike the utilization/ISO shape parse_claude reads.
  def statusline_rate_limits
    {
      'five_hour' => { 'used_percentage' => 23.5, 'resets_at' => (NOW + 8040).to_i },
      'seven_day' => { 'used_percentage' => 41.2, 'resets_at' => (NOW + 356_400).to_i }
    }
  end

  # Shape of GET /api/oauth/usage — already in parse_claude's vocabulary, and
  # the only source of extra_usage.
  def oauth_usage_payload
    {
      'five_hour' => { 'utilization' => 12.0, 'resets_at' => (NOW + 8040).iso8601 },
      'seven_day' => { 'utilization' => 30.0, 'resets_at' => (NOW + 356_400).iso8601 },
      'extra_usage' => { 'is_enabled' => true, 'utilization' => 18.0 }
    }
  end

  def with_claude_snapshot(payload, age: 0)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'claude-limits.json')
      File.write(path, payload.to_json)
      File.utime(NOW - age, NOW - age, path)
      yield path
    end
  end

  def grok_signal_file(dir, name, at, compacted, context)
    session = File.join(dir, name)
    FileUtils.mkdir_p(session)
    File.write(
      File.join(session, 'summary.json'),
      JSON.generate('updated_at' => at.iso8601)
    )
    path = File.join(session, 'signals.json')
    File.write(
      path,
      JSON.generate(
        'primaryModelId' => 'grok-composer-2.5-fast',
        'totalTokensBeforeCompaction' => compacted,
        'contextTokensUsed' => context
      )
    )
    path
  end

  def grok_inference_event(at, sid, prompt, completion)
    {
      'ts' => at.iso8601,
      'sid' => sid,
      'msg' => 'shell.turn.inference_done',
      'ctx' => {
        'prompt_tokens' => prompt,
        'completion_tokens' => completion,
        'cached_prompt_tokens' => 0,
        'reasoning_tokens' => 0
      }
    }.to_json
  end
end

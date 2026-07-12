# frozen_string_literal: true

require 'fileutils'
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
    assert_includes table, 'session util'
    assert_includes table, 'session reset'
    assert_includes table, 'week reset'
    assert_includes table, 'Codex'
    assert_includes table, '82%'
  end

  def test_fetch_claude_returns_skip_note
    data, note = LlmUsage.fetch_claude_usage
    assert_nil data
    assert_equal 'claude: no local snapshot', note
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
end
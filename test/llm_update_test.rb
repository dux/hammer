require_relative 'test_helper'
require_relative '../recipes/lib/llm/update'

class LlmUpdateTest < Minitest::Test
  GROK_MODELS = <<~OUT
    You are not authenticated.

    Default model: grok-4.6

    Available models:
      * grok-4.6 (default)
      - grok-4.5
      - grok-code-fast-1
  OUT

  OPENCODE_MODELS = <<~OUT
    opencode/claude-opus-5
    opencode/gemini-3.1-pro
    anthropic/claude-sonnet-5
  OUT

  def test_parse_version_handles_every_cli_shape
    assert_equal '2.1.268', LlmUpdate.parse_version("2.1.268 (Claude Code)\n")
    assert_equal '0.154.0', LlmUpdate.parse_version("codex-cli 0.154.0\n")
    assert_equal '1.0.25',  LlmUpdate.parse_version("grok 1.0.25 (f7e67d6988e2) [stable]\n")
    assert_equal '1.18.30', LlmUpdate.parse_version("1.18.30\n")
    assert_nil LlmUpdate.parse_version('')
    assert_nil LlmUpdate.parse_version("command not found\n")
  end

  def test_parse_models_skips_grok_preamble_and_default_marker
    assert_equal %w[grok-4.5 grok-4.6 grok-code-fast-1], LlmUpdate.parse_models('grok', GROK_MODELS)
  end

  def test_parse_models_reads_opencode_bare_lines
    assert_equal %w[anthropic/claude-sonnet-5 opencode/claude-opus-5 opencode/gemini-3.1-pro],
                 LlmUpdate.parse_models('opencode', OPENCODE_MODELS)
  end

  def test_parse_models_on_empty_output
    assert_empty LlmUpdate.parse_models('grok', '')
    assert_empty LlmUpdate.parse_models('opencode', "no providers configured\n")
  end

  # A tool with a models command but no parser would raise on `--update`.
  def test_every_model_tool_has_a_parser
    LlmLaunch::TOOLS.each do |name, spec|
      next unless spec[:models]
      assert LlmUpdate::MODEL_RE.key?(name), "#{name} lists models but has no MODEL_RE entry"
    end
  end

  def test_parse_models_without_a_parser_returns_empty
    assert_empty LlmUpdate.parse_models('claude', 'anything')
  end

  def test_diff_reports_added_and_removed
    assert_equal [%w[c], %w[a]], LlmUpdate.diff(%w[a b], %w[b c])
    assert_equal [[], []], LlmUpdate.diff(%w[a b], %w[a b])
    assert_equal [%w[a b], []], LlmUpdate.diff([], %w[a b])
  end
end

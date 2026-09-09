require_relative 'test_helper'
require_relative '../recipes/lib/llm/browser'
require 'tmpdir'

class LlmBrowserTest < Minitest::Test
  def test_llm_prefix_first_match_wins
    assert_equal 'claude', LlmBrowser.llm(nil)
    assert_equal 'claude', LlmBrowser.llm('')
    assert_equal 'claude', LlmBrowser.llm('c')
    assert_equal 'codex',  LlmBrowser.llm('co')
    assert_equal 'ollama', LlmBrowser.llm('o')
    assert_nil LlmBrowser.llm('x')
  end

  def test_env_points_bun_at_the_global_store
    assert_equal({ 'NODE_PATH' => LlmBrowser::GLOBAL_MODULES }, LlmBrowser.env)
    assert LlmBrowser::GLOBAL_MODULES.end_with?('.bun/install/global/node_modules')
  end

  def test_run_argv_url_then_instructions_then_flags
    argv = LlmBrowser.run_argv('https://x.com', ['act: click', 'extract: title'], llm: 'codex')
    assert_equal ['bun', LlmBrowser::RUNNER, 'https://x.com', 'act: click', 'extract: title', '--llm', 'codex'], argv
  end

  def test_run_argv_adds_headed_and_shot_only_when_given
    argv = LlmBrowser.run_argv('https://x.com', [], headed: true, shot: 'out.png')
    assert_equal ['bun', LlmBrowser::RUNNER, 'https://x.com', '--llm', 'claude', '--headed', '--shot', 'out.png'], argv
    refute_includes LlmBrowser.run_argv('https://x.com'), '--headed'
    refute_includes LlmBrowser.run_argv('https://x.com'), '--shot'
  end

  def test_script_argv_expands_path_and_forwards_extra
    argv = LlmBrowser.script_argv('~/x/script.ts', %w[--foo 1])
    assert_equal ['bun', LlmBrowser::RUNNER, '--script', File.join(Dir.home, 'x/script.ts'), '--foo', '1'], argv
  end

  def test_setup_argv_installs_both_packages_globally
    assert_equal %w[bun add -g @browserbasehq/stagehand zod], LlmBrowser.setup_argv
  end

  def test_installed_and_check_look_at_the_given_store
    Dir.mktmpdir do |dir|
      refute LlmBrowser.installed?(modules: dir)
      LlmBrowser::PACKAGES.each { |pkg| FileUtils.mkdir_p(File.join(dir, pkg)) }
      assert LlmBrowser.installed?(modules: dir)

      check = LlmBrowser.check(modules: dir, chrome: File.join(dir, 'missing'))
      assert_equal %w[bun stagehand chrome claude codex ollama], check.keys
      assert_equal true,  check['stagehand']
      assert_equal false, check['chrome']
    end
  end
end

require_relative 'test_helper'
require_relative '../recipes/lib/llm/launch'

class LlmLaunchTest < Minitest::Test
  def test_tool_prefix_first_match_wins
    assert_equal 'claude',   LlmLaunch.tool(nil)
    assert_equal 'claude',   LlmLaunch.tool('c')
    assert_equal 'codex',    LlmLaunch.tool('co')
    assert_equal 'grok',     LlmLaunch.tool('g')
    assert_equal 'opencode', LlmLaunch.tool('o')
    assert_nil LlmLaunch.tool('x')
  end

  def test_switch_mapping_per_tool
    assert_equal %w[claude -c --dangerously-skip-permissions],
                 LlmLaunch.build('claude', continue: true, full: true).argv
    assert_equal %w[codex resume --last --dangerously-bypass-approvals-and-sandbox],
                 LlmLaunch.build('codex', continue: true, full: true).argv
    assert_equal %w[grok -c --always-approve], LlmLaunch.build('grok', continue: true, full: true).argv
    assert_equal %w[opencode -c --auto], LlmLaunch.build('opencode', continue: true, full: true).argv
  end

  def test_extra_args_pass_through_last
    launch = LlmLaunch.build('claude', %w[--model opus], continue: true)
    assert_equal %w[claude -c --model opus], launch.argv
    assert_equal({}, launch.env)
    assert_equal [], launch.files
  end

  def test_agents_walk_home_to_cwd_and_skip_git_root_for_native_tools
    in_tree do |home, cwd|
      claude = LlmLaunch.build('claude', agents: true, cwd: cwd, home: home)
      assert_equal %w[AGENTS.md dev/AGENTS.md dev/proj/AGENTS.md], rel(claude.files, home)
      assert_equal '--append-system-prompt', claude.argv[1]
      assert_includes claude.argv[2], "## #{home}/dev/AGENTS.md"
      assert_includes claude.argv[2], 'root rule'

      codex = LlmLaunch.build('codex', agents: true, cwd: cwd, home: home)
      assert_equal %w[AGENTS.md dev/AGENTS.md], rel(codex.files, home)
      assert_equal '-c', codex.argv[1]
      assert codex.argv[2].start_with?('developer_instructions=Project instructions')

      opencode = LlmLaunch.build('opencode', agents: true, cwd: cwd, home: home)
      assert_equal %w[opencode], opencode.argv
      assert_equal({ 'instructions' => ["#{home}/AGENTS.md", "#{home}/dev/AGENTS.md"] },
                   JSON.parse(opencode.env['OPENCODE_CONFIG_CONTENT']))
    end
  end

  def test_agents_outside_git_stop_above_cwd_for_native_tools
    in_tree(git: false) do |home, cwd|
      assert_equal %w[AGENTS.md dev/AGENTS.md dev/proj/AGENTS.md],
                   rel(LlmLaunch.build('claude', agents: true, cwd: cwd, home: home).files, home)
      assert_equal %w[AGENTS.md dev/AGENTS.md],
                   rel(LlmLaunch.build('grok', agents: true, cwd: cwd, home: home).files, home)
    end
  end

  def test_agents_with_nothing_found_adds_nothing
    Dir.mktmpdir do |home|
      launch = LlmLaunch.build('claude', agents: true, cwd: home, home: home)
      assert_equal %w[claude], launch.argv
    end
  end

  private

  # home/AGENTS.md, home/dev/AGENTS.md, home/dev/proj/AGENTS.md; proj is a git repo
  def in_tree(git: true)
    Dir.mktmpdir do |home|
      home = File.realpath(home)
      cwd = File.join(home, 'dev', 'proj')
      FileUtils.mkdir_p(cwd)
      File.write(File.join(home, 'AGENTS.md'), 'home rule')
      File.write(File.join(home, 'dev', 'AGENTS.md'), 'dev rule')
      File.write(File.join(cwd, 'AGENTS.md'), 'root rule')
      system('git', 'init', '-q', cwd) if git
      yield home, cwd
    end
  end

  def rel(files, home)
    files.map { |f| f.to_s.sub("#{home}/", '') }
  end
end

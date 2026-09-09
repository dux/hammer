# frozen_string_literal: true

# Builds the commands `llm browser:*` hands to Bun. Stagehand is installed
# globally with `bun add -g`, and Bun resolves imports from NODE_PATH, so the
# TypeScript under browser/ can live here while the package lives in the
# global store. Nothing in this module runs Bun or the network - that is what
# keeps it testable.
module LlmBrowser
  GLOBAL_MODULES ||= File.join(Dir.home, '.bun/install/global/node_modules')
  SCRIPT_DIR     ||= File.join(__dir__, 'browser')
  RUNNER         ||= File.join(SCRIPT_DIR, 'run.ts')
  PACKAGES       ||= %w[@browserbasehq/stagehand zod].freeze
  CHROME         ||= '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

  # Who answers Stagehand's act / observe / extract questions. claude and codex
  # go through their CLIs (subscription, no API key); ollama is Stagehand's own
  # provider talking to the local daemon.
  LLMS ||= %w[claude codex ollama].freeze

  # First backend whose name starts with the prefix: `c` is claude, `co` codex,
  # `o` ollama. No prefix means claude.
  def self.llm(prefix)
    return LLMS.first if prefix.nil? || prefix.empty?
    LLMS.find { |name| name.start_with?(prefix) }
  end

  def self.env
    { 'NODE_PATH' => GLOBAL_MODULES }
  end

  def self.setup_argv
    ['bun', 'add', '-g', *PACKAGES]
  end

  def self.run_argv(url, instructions = [], llm: 'claude', headed: false, shot: nil)
    argv = ['bun', RUNNER, url, *instructions, '--llm', llm]
    argv << '--headed' if headed
    argv.push('--shot', shot) if shot
    argv
  end

  def self.script_argv(path, extra = [])
    ['bun', RUNNER, '--script', File.expand_path(path), *extra]
  end

  def self.installed?(modules: GLOBAL_MODULES)
    PACKAGES.all? { |pkg| File.directory?(File.join(modules, pkg)) }
  end

  # What `browser:setup` reports: name => true/false, in the order it prints.
  def self.check(modules: GLOBAL_MODULES, chrome: CHROME)
    {
      'bun'       => command?('bun'),
      'stagehand' => installed?(modules: modules),
      'chrome'    => File.exist?(chrome),
      'claude'    => command?('claude'),
      'codex'     => command?('codex'),
      'ollama'    => command?('ollama'),
    }
  end

  def self.command?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
  end
end

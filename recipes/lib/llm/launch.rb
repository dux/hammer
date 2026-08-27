# frozen_string_literal: true

require 'json'
require 'pathname'

# Builds the command `llm wrap:run` hands to LlmWrap: picks the agent CLI by
# prefix and maps the generic -c / -f / -a switches to what that CLI takes.
module LlmLaunch
  Launch = Struct.new(:argv, :env, :files)

  # :agents gets the combined AGENTS.md text and the file paths, and answers
  # with the argv to add and/or env to set - opencode has no flag for
  # instructions, only inline config, and that one takes paths.
  TOOLS ||= {
    'claude'   => { continue: %w[-c],            full: %w[--dangerously-skip-permissions],
                    agents: ->(text, _files) { { args: ['--append-system-prompt', text] } } },
    'codex'    => { continue: %w[resume --last], full: %w[--dangerously-bypass-approvals-and-sandbox],
                    agents: ->(text, _files) { { args: ['-c', "developer_instructions=#{text}"] } } },
    'grok'     => { continue: %w[-c],            full: %w[--always-approve],
                    agents: ->(text, _files) { { args: ['--rules', text] } } },
    'opencode' => { continue: %w[-c],            full: %w[--auto],
                    agents: ->(_text, files) { { env: { 'OPENCODE_CONFIG_CONTENT' => { instructions: files }.to_json } } } },
  }.freeze

  # Read AGENTS.md from the git root down on their own; -a only adds the
  # files above it for these. Claude reads CLAUDE.md, so it gets the chain.
  NATIVE_AGENTS ||= %w[codex grok opencode].freeze

  # First tool whose name starts with the prefix, in TOOLS order: `c` is
  # claude, `co` codex. No prefix means claude.
  def self.tool(prefix)
    return 'claude' if prefix.nil? || prefix.empty?
    TOOLS.keys.find { |name| name.start_with?(prefix) }
  end

  def self.build(tool, extra = [], continue: false, full: false, agents: false, cwd: Dir.pwd, home: Dir.home)
    spec = TOOLS.fetch(tool)
    argv = [tool]
    argv.concat(spec[:continue]) if continue
    argv.concat(spec[:full]) if full

    files = agents ? agents_files(tool, cwd: cwd, home: home) : []
    env = {}
    if files.any?
      added = spec[:agents].call(agents_text(files), files.map(&:to_s))
      argv.concat(added[:args] || [])
      env.update(added[:env] || {})
    end

    argv.concat(extra)
    Launch.new(argv, env, files)
  end

  # AGENTS.md from home down to cwd, outermost first. For NATIVE_AGENTS tools
  # the walk stops above the git root - or above cwd outside git, since that is
  # what they take as the project then.
  def self.agents_files(tool, cwd: Dir.pwd, home: Dir.home)
    stop = nil
    if NATIVE_AGENTS.include?(tool)
      stop = IO.popen(['git', '-C', cwd, 'rev-parse', '--show-toplevel'], err: File::NULL, &:read).to_s.strip
      stop = cwd if stop.empty?
    end

    Pathname(cwd).ascend
      .select { |dir| dir.to_s.start_with?(home) }
      .reject { |dir| stop && dir.to_s.start_with?(stop) }
      .reverse
      .map { |dir| dir + 'AGENTS.md' }
      .select(&:file?)
  end

  def self.agents_text(files)
    body = files.map { |f| "## #{f}\n\n#{f.read.strip}\n" }.join("\n")
    "Project instructions (AGENTS.md), broad to specific:\n\n#{body}"
  end
end

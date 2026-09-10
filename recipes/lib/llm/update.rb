# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'launch'

# Backs `llm wrap:run --update` (`ai --update`): runs each agent CLI's own
# updater and reports old -> new, then re-reads the model lists and shows what
# appeared or disappeared since the last run. None of these tools download
# model weights - the models are API-side, so the list is the thing that moves.
module LlmUpdate
  extend Hammer::Shell

  CACHE_PATH ||= File.expand_path('~/.cache/llm/models.json')
  WIDTH      ||= LlmLaunch::TOOLS.keys.map(&:size).max

  # How each CLI prints its list: grok bullets it under a preamble ("You are
  # not authenticated." when logged out) and marks the default, opencode prints
  # one bare provider/model per line.
  MODEL_RE ||= {
    'grok'     => /\A\s*[*-]\s+(\S+)/,
    'opencode' => %r{\A(\S+/\S+)\z},
  }.freeze

  module_function

  # Returns the exit status - non-zero if any updater failed.
  def run(tools)
    rows = tools.map { |tool| update_one(tool) }
    say ''
    rows.each { |row| report(row) }
    report_models(rows.select { |row| row[:installed] }.map { |row| row[:tool] })
    rows.any? { |row| row[:failed] } ? 1 : 0
  end

  def update_one(tool)
    return { tool: tool, installed: false } unless command?(tool)

    argv = LlmLaunch::TOOLS.fetch(tool)[:update]
    before = version(tool)
    say.gray "$ #{argv.join(' ')}"
    ok = system(*argv)
    { tool: tool, installed: true, before: before, after: version(tool), failed: !ok }
  end

  def report(row)
    name = row[:tool].ljust(WIDTH)
    return say.gray("* #{name}  not installed") unless row[:installed]
    return say.red("* #{name}  update failed") if row[:failed]

    before, after = row.values_at(:before, :after)
    if before && after && before != after
      say.green "* #{name}  #{before} -> #{after}"
    elsif after
      say "* #{name}  #{after} (latest)"
    else
      say "* #{name}  #{before || 'unknown version'}"
    end
  end

  def report_models(tools)
    tools = tools.select { |tool| LlmLaunch::TOOLS.fetch(tool)[:models] }
    return if tools.empty?

    cache = cache_read
    say ''
    say 'models'
    tools.each { |tool| cache[tool] = report_model_list(tool, cache[tool]) }
    cache_write(cache)
  end

  # Prints one tool's list against the previously cached one, and answers with
  # the fresh list so the caller can write it back.
  def report_model_list(tool, old)
    list = models(tool)
    name = tool.ljust(WIDTH)
    if list.empty?
      say.gray "  #{name}  no models listed"
      return old || []
    end

    say "  #{name}  #{list.size} models"
    unless old
      say.gray '    (first run)'
      return list
    end

    added, removed = diff(old, list)
    say.gray('    unchanged') if added.empty? && removed.empty?
    added.each   { |model| say.green "    + #{model}" }
    removed.each { |model| say.gray "    - #{model}" }
    list
  end

  def version(tool)
    parse_version(capture(LlmLaunch::TOOLS.fetch(tool)[:version]))
  end

  def models(tool)
    parse_models(tool, capture(LlmLaunch::TOOLS.fetch(tool)[:models]))
  end

  # `2.1.268 (Claude Code)`, `codex-cli 0.154.0`, `grok 1.0.25 (f7e67d6) [stable]`, `1.18.30`
  def parse_version(out)
    out.to_s.lines.first.to_s[/\d+\.\d+(?:\.\d+)*/]
  end

  def parse_models(tool, out)
    re = MODEL_RE[tool]
    return [] unless re
    out.to_s.lines.filter_map { |line| line.rstrip[re, 1] }.uniq.sort
  end

  def diff(old, new)
    [new - old, old - new]
  end

  def cache_read
    JSON.parse(File.read(CACHE_PATH))
  rescue StandardError
    {}
  end

  def cache_write(data)
    FileUtils.mkdir_p(File.dirname(CACHE_PATH))
    tmp = "#{CACHE_PATH}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(data))
    File.rename(tmp, CACHE_PATH)
  end

  def capture(argv)
    IO.popen(argv, err: %i[child out], &:read).to_s
  rescue StandardError
    ''
  end

  def command?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
  end
end

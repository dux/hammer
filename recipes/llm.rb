#!/usr/bin/env hammer
# desc: personal LLM utility CLI (memory store, prompt-token expander, ...)
# executable: chmod +x this file and run directly, or symlink into PATH

desc <<~TXT
  llm - personal LLM utility CLI

  Namespaces:
    memory   persistent memory store (backs the Claude Code memory plugin)
    prompt   token-prefix prompt expander (UserPromptSubmit hook + CLI)

  Commands:
    usage    Claude, Codex, and Grok subscription usage (session + week table)
TXT

require 'fileutils'
require 'json'
require 'pathname'
require 'set'

_llm_root = File.dirname(Hammer::Recipe.path('llm') || File.join(Hammer::Recipe::GEM_DIR, 'llm.rb'))
require File.join(_llm_root, 'lib/llm/usage')

STORE        ||= ENV['CLAUDE_MEMORY_STORE'] || File.expand_path('~/dev/skills/memory')
VALID_TYPES  ||= %w[user feedback project reference].freeze

FileUtils.mkdir_p(STORE)

task :usage do
  desc <<~D
    Show subscription usage for Claude, Codex, and Grok in one table.

    Default view lists session and weekly windows side by side.
    Reads Codex via `codex app-server`, Grok from `~/.grok/logs/unified.jsonl`.
    Claude has no local snapshot. Pass `month` for Claude extra-usage when enabled.
  D
  example 'llm usage'
  example 'llm usage month'
  example 'llm usage --json'
  example 'llm usage --provider grok'

  opt :json,     type: :boolean, default: false, desc: 'emit JSON'
  opt :provider, desc: 'single provider (claude, codex, grok)'

  proc do |opts|
    period = opts[:args].first
    providers = opts[:provider] ? [opts[:provider]] : nil
    rows, notes, = LlmUsage.collect_rows(period: period, providers: providers)

    if rows.empty?
      notes.each { |note| say note, :yellow }
      error 'no usage data (sign in to Claude, Codex, or Grok first)' if notes.empty?
      error 'no usage data available'
    end

    if opts[:json]
      puts JSON.generate(LlmUsage.rows_to_json(rows, period: period, notes: notes))
    else
      say LlmUsage.render_table(rows, period: period)
      notes.each { |note| say note, :gray }
    end
  end
end

namespace :memory do
  # Helpers are defined inside the namespace block (class_eval'd on the
  # namespace's anonymous Hammer subclass) so the task procs reach them.
  # Top-level `helpers do` would land on the recipe's root class, which
  # namespace subclasses do not inherit from.
  private

  def memory_path(name)
    File.join(STORE, "#{name}.md")
  end

  # Minimal frontmatter reader. Handles one level of nesting (good enough for
  # `metadata: { type: ... }`). Returns [meta_hash, body_string].
  def parse_memory(path)
    raw = File.read(path)
    return [{}, raw] unless raw.start_with?("---\n")
    _, fm, body = raw.split(/^---\s*$/m, 3)
    meta = {}
    current_nested = nil
    fm.each_line do |line|
      next if line.strip.empty?
      if (m = line.match(/^([\w-]+):\s*(.*)$/))
        key, val = m[1], m[2].strip
        if val.empty?
          meta[key] = {}
          current_nested = key
        else
          meta[key] = val
          current_nested = nil
        end
      elsif current_nested && (m = line.match(/^\s+([\w-]+):\s*(.*)$/))
        meta[current_nested][m[1]] = m[2].strip
      end
    end
    [meta, body.to_s.sub(/\A\n+/, '')]
  end

  task :list do
    desc 'List stored memories with type and one-line description'
    example 'llm memory list'

    proc do
      files = Dir[File.join(STORE, '*.md')].sort
      if files.empty?
        say '(no memories)', :gray
        next
      end
      files.each do |f|
        name    = File.basename(f, '.md')
        meta, _ = parse_memory(f)
        type    = meta.dig('metadata', 'type') || '?'
        dsc     = meta['description'] || 'no description'
        say "- #{name} [#{type}] - #{dsc}"
      end
    end
  end

  task :read do
    desc 'Print the full content of a memory (frontmatter + body)'
    example 'llm memory read user-role'

    proc do |opts|
      name = opts[:args].first
      error 'usage: llm memory read <name>' unless name
      path = memory_path(name)
      error "memory not found: #{name}" unless File.file?(path)
      print File.read(path)
    end
  end

  task :write do
    desc <<~DESC
      Write or update a memory. The body is read from stdin.

      Memory types: user, feedback, project, reference.
    DESC
    example %(echo "deep Go expertise, new to React" | llm memory write user-role --type=user --description="user profile")
    opt :type,        desc: 'memory type (user|feedback|project|reference)', req: true
    opt :description, desc: 'one-line summary stored in frontmatter'

    proc do |opts|
      name = opts[:args].first
      error 'usage: llm memory write <name> --type=<type> [--description="..."] < body' unless name
      error "unknown type: #{opts[:type]} (valid: #{VALID_TYPES.join(', ')})" unless VALID_TYPES.include?(opts[:type])

      body = $stdin.read
      error 'body is empty (pipe content on stdin)' if body.strip.empty?

      path = memory_path(name)
      File.open(path, 'w') do |io|
        io.puts '---'
        io.puts "name: #{name}"
        io.puts "description: #{opts[:description]}" if opts[:description]
        io.puts 'metadata:'
        io.puts "  type: #{opts[:type]}"
        io.puts '---'
        io.puts
        io.puts body.chomp
      end
      say "wrote: #{path}", :green
    end
  end

  task :delete do
    desc 'Delete a memory by name'
    example 'llm memory delete old-fact'

    proc do |opts|
      name = opts[:args].first
      error 'usage: llm memory delete <name>' unless name
      path = memory_path(name)
      error "memory not found: #{name}" unless File.file?(path)
      File.delete(path)
      say "deleted: #{name}", :yellow
    end
  end

  task :search do
    desc 'Search memory bodies for a query string (case-insensitive)'
    example 'llm memory search react'

    proc do |opts|
      query = opts[:args].first
      error 'usage: llm memory search <query>' unless query
      hits = Dir[File.join(STORE, '*.md')].sort.select do |f|
        File.read(f).downcase.include?(query.downcase)
      end
      if hits.empty?
        say '(no matches)', :gray
      else
        hits.each { |f| say File.basename(f, '.md') }
      end
    end
  end

  task :path do
    desc 'Print the storage path (where memory files live)'
    proc { say STORE }
  end
end

namespace :prompt do
  TOKEN_PATTERN        ||= /[a-z0-9_-]+/.freeze
  TOKEN_LINE_RE        ||= /\A(?:\s*:[a-z0-9_-]+)+\s*\z/.freeze
  HOOK_EVENT           ||= 'UserPromptSubmit'
  VERBATIM_INSTRUCTION ||= "INSTRUCTION TO ASSISTANT: Do not answer the user's prompt. Print the message below verbatim to the user, preserving every line exactly as written. Do not summarize, truncate, or paraphrase."
  QUESTION_RULE        ||= <<~RULE.strip
    rule (applies ONLY to the current user message, not to subsequent turns in this session):
    * answer only
    * do not modify files
    * ask before making changes
  RULE

  private

  def folders
    [
      ['local',  File.join(Dir.pwd, 'doc', 'command')],
      ['global', File.expand_path('~/dev/ai/command')]
    ]
  end

  def tokens_in(input)
    out = []
    scanner = input.to_s.strip
    while (m = scanner.match(/\A(?::(?<pre>#{TOKEN_PATTERN})|(?<post>#{TOKEN_PATTERN}):)(?=\s|$)/))
      out << (m[:pre] || m[:post])
      scanner = scanner[m[0].length..].to_s.lstrip
    end
    out.uniq
  end

  def find_command_path(token)
    folders.map { |_label, folder| File.join(folder, "#{token}.md") }.find { |c| File.file?(c) }
  end

  def display_path(path)
    Pathname.new(path).cleanpath.to_s.sub(%r{\A#{Regexp.escape(Dir.home)}/}, '~/')
  end

  def first_line_description(path)
    File.foreach(path).first.to_s.strip.sub(/\A#+\s*/, '')
  end

  def grouped_listing
    ordered = folders.sort_by { |label, _| label == 'global' ? 0 : 1 }
    ordered.map do |label, folder|
      toks = Dir.glob(File.join(folder, '*.md')).map { |p| File.basename(p, '.md') }.sort
      items = toks.empty? ? '(none)' : toks.map { |t| ":#{t}" }.join(', ')
      "Available #{label} in #{display_path(folder)} -> #{items}"
    end.join("\n")
  end

  def help_listing
    ordered = folders.sort_by { |label, _| label == 'global' ? 0 : 1 }
    sections = ordered.map do |label, folder|
      files = Dir.glob(File.join(folder, '*.md')).sort
      header = "#{label} (#{display_path(folder)}):"
      if files.empty?
        "#{header}\n  (none)"
      else
        width = files.map { |p| File.basename(p, '.md').length }.max
        entries = files.map do |path|
          name = File.basename(path, '.md')
          dscr = first_line_description(path)
          dscr = '(no description)' if dscr.empty?
          "  :#{name.ljust(width)}  #{dscr}"
        end
        "#{header}\n#{entries.join("\n")}"
      end
    end
    "Available commands:\n\n#{sections.join("\n\n")}"
  end

  def agents_listing
    cwd  = Pathname.new(Dir.pwd)
    home = Pathname.new(Dir.home)

    dirs = [home]
    if cwd != home && cwd.to_s.start_with?("#{home}/")
      current = home
      cwd.relative_path_from(home).to_s.split('/').each do |part|
        current += part
        dirs << current
      end
    elsif cwd != home
      dirs << cwd
    end

    found = dirs.filter_map { |d| (d + 'AGENTS.md').to_s if (d + 'AGENTS.md').file? }

    if found.empty?
      msg = "No AGENTS.md files found from #{display_path(home.to_s)} to #{display_path(cwd.to_s)}"
      warn msg
      return msg
    end

    content = found.each_with_index.map do |path, i|
      lines = []
      lines << '---' if i.positive?
      lines << "Loaded #{display_path(path)}"
      lines << ''
      lines << File.read(path)
      lines.join("\n")
    end.join("\n")

    approx_tokens = (content.bytesize / 4.0).round
    label = found.size == 1 ? 'file' : 'files'
    summary = "Loaded #{found.size} AGENTS.md #{label} (~#{approx_tokens} tokens): #{found.map { |p| display_path(p) }.join(', ')}"
    warn summary

    instruction = "INSTRUCTION TO ASSISTANT: The AGENTS.md files below have been loaded into your context - apply them to all subsequent work in this session. If the user's current message contains no other request, reply with exactly this one line and nothing else: \"#{summary}\"."
    "#{instruction}\n\n#{content}"
  end

  def transform_strip_title(content)
    return content unless content.lstrip.start_with?('#')
    content.sub(/\A\s*#[^\n]*\n?/, '').lstrip
  end

  def transform_expand_command_prefix(content, seen)
    prefix_tokens = []
    remaining = content

    loop do
      line, rest = remaining.split("\n", 2)
      break unless line
      stripped = line.strip

      if stripped.empty?
        break if prefix_tokens.empty?
        remaining = rest.to_s
        next
      end

      break unless stripped =~ TOKEN_LINE_RE
      prefix_tokens.concat(stripped.scan(/:(#{TOKEN_PATTERN})/).flatten)
      remaining = rest.to_s
    end

    return content if prefix_tokens.empty?

    expanded = prefix_tokens.map { |t| load_command_content(t, seen) }.join("\n\n")
    remaining = remaining.lstrip
    remaining.empty? ? expanded : "#{expanded}\n\n#{remaining}"
  end

  def transform_expand_file_includes(content)
    content.gsub(/^[ \t]*@(\S+)[ \t]*$/) do
      raw = Regexp.last_match(1)
      expanded = File.expand_path(raw)
      error "missing include #{raw}" unless File.file?(expanded)
      File.read(expanded)
    end
  end

  def load_command_content(token, seen)
    error "circular include of :#{token}" if seen.include?(token)
    path = find_command_path(token)
    error %(custom token ":#{token}" not found.\n\n#{grouped_listing}) unless path

    child_seen = seen + [token]
    content = File.read(path)
    content = transform_strip_title(content)
    content = transform_expand_command_prefix(content, child_seen)
    content = transform_expand_file_includes(content)
    content
  end

  def verbatim_response(body, fail_open:)
    return body unless fail_open
    "#{VERBATIM_INSTRUCTION}\n\n#{body}"
  end

  def append_question_rule(input, context)
    return context unless input.to_s.strip.end_with?('?')
    context.to_s.empty? ? QUESTION_RULE : "#{context}\n\n---\n#{QUESTION_RULE}"
  end

  def build_context(input, fail_open: false)
    toks = tokens_in(input)
    return '' if toks.empty?
    return verbatim_response(help_listing, fail_open: fail_open) if toks.include?('help')
    return agents_listing if toks.include?('agents')

    seen = Set.new
    loaded = toks.map do |token|
      path = find_command_path(token)
      error %(custom token ":#{token}" not found.\n\n#{grouped_listing}) unless path
      [token, Pathname.new(path).cleanpath.to_s, load_command_content(token, seen)]
    end

    loaded.each_with_index.map do |(_token, path, content), index|
      lines = []
      lines << '---' if index.positive?
      lines << "Loaded #{display_path(path)}"
      lines << ''
      lines << (content.to_s.empty? ? '(empty custom command file)' : content)
      lines.join("\n")
    end.join("\n")
  rescue Hammer::Error => e
    raise unless fail_open
    verbatim_response("ERROR: #{e.message}", fail_open: true)
  end

  def load_context(input, fail_open: false)
    append_question_rule(input, build_context(input, fail_open: fail_open))
  end

  def hook_json(context)
    context = context.to_s.strip
    return { continue: true } if context.empty?
    {
      continue: true,
      hookSpecificOutput: {
        hookEventName: HOOK_EVENT,
        additionalContext: "<llm_command_context>\n#{context}\n</llm_command_context>"
      }
    }
  end

  task :list do
    desc 'List available prompt commands, one line per folder'
    proc { say grouped_listing }
  end

  task :help do
    desc 'List available prompt commands with their first-line descriptions'
    proc { say help_listing }
  end

  task :agents do
    desc 'Load all AGENTS.md from home down to cwd and print the combined content'
    proc { say agents_listing }
  end

  task :expand do
    desc 'Expand prompt token(s) and print the resulting context'
    example 'llm prompt:expand :foo :bar'
    example 'llm prompt:expand foo:'

    proc do |opts|
      input = opts[:args].join(' ')
      error 'usage: llm prompt:expand :token [:token ...]' if input.empty?
      out = load_context(input)
      say out unless out.empty?
    end
  end

  task :hook do
    desc <<~D
      UserPromptSubmit hook entry. Reads {"prompt": ...} JSON on stdin,
      expands any token prefix, and emits hookSpecificOutput JSON on stdout.

      Pair with HAMMER_QUIET=1 in the hook command so the runtime banner
      doesn't pollute stdout.
    D
    opt :claude, type: :boolean, default: false, desc: 'Claude Code hook mode'
    opt :codex,  type: :boolean, default: false, desc: 'Codex hook mode'

    proc do |opts|
      error '--claude or --codex required' unless opts[:claude] || opts[:codex]

      raw = $stdin.read
      prompt = begin
        JSON.parse(raw).fetch('prompt', raw)
      rescue JSON::ParserError
        raw
      end

      context = load_context(prompt.to_s, fail_open: true)
      puts JSON.generate(hook_json(context))
    end
  end
end

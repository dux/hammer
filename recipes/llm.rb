#!/usr/bin/env hammer
# desc: personal LLM utility CLI (memory store, prompt-token expander, ...)
# executable: chmod +x this file and run directly, or symlink into PATH

desc <<~TXT
  llm - personal LLM utility CLI

  Namespaces:
    memory   persistent memory store (backs the Claude Code memory plugin)
    plan     apply a /plan bundle - sha1 checked, drift aware
    prompt   token-prefix prompt expander (UserPromptSubmit hook + CLI)
    todo     per-project task queue for agents (./LLM_TODO.local.md)

  Commands:
    usage    subscription limits and per-model token usage
    wrap     run a command with your last two prompts pinned to the screen
TXT

require 'fileutils'
require 'json'
require 'pathname'
require 'set'

# Resolve next to this recipe file (realpath so PATH symlinks to a dev
# checkout still load matching lib/, not an older installed gem copy).
_llm_root = File.dirname(File.realpath(__FILE__))
require File.join(_llm_root, 'lib/llm/usage')
require File.join(_llm_root, 'lib/llm/plan')

STORE        ||= ENV['CLAUDE_MEMORY_STORE'] || File.expand_path('~/dev/ai/memory')
VALID_TYPES  ||= %w[user feedback project reference].freeze

FileUtils.mkdir_p(STORE)

task :usage do
  desc <<~D
    Show subscription limits and per-model token usage for Claude, Codex, and Grok.

    Default view lists session and weekly windows side by side.
    Local Claude, Codex, and Grok sessions provide calendar day, week, and month token totals.
    Reads Codex via `codex app-server`; Grok billing + tokens from `~/.grok/logs/unified.jsonl`
    (inference_done events). Claude 5h/week windows come from the statusline snapshot at
    `~/.cache/llm/claude-limits.json`, falling back to the OAuth usage API. `month` shows
    Claude extra-usage credits (API only, and only when you've enabled them).
  D
  example 'usage'
  example 'usage month'
  example 'usage --json'
  example 'usage --provider grok'

  # :period is declared first on purpose — the parser fills un-set scalar opts
  # from positionals in declaration order, so `llm usage month` must reach
  # :period before :provider can claim it.
  opt :period,   desc: 'window to show (week, month)', placeholder: 'week|month'
  opt :json,     type: :boolean, default: false, desc: 'emit JSON'
  opt :provider, desc: 'single provider (claude, codex, grok)'

  proc do |opts|
    period = opts[:period]
    providers = opts[:provider] ? [opts[:provider]] : nil
    rows, notes, = LlmUsage.collect_rows(period: period, providers: providers)
    token_rows = LlmUsage.collect_token_rows(providers: providers)

    if rows.empty? && token_rows.empty?
      notes.each { |note| say note, :yellow }
      error 'no usage data (sign in to Claude, Codex, or Grok first)' if notes.empty?
      error 'no usage data available'
    end

    if opts[:json]
      puts JSON.generate(
        LlmUsage.rows_to_json(rows, period: period, notes: notes, token_rows: token_rows)
      )
    else
      tables = []
      tables << LlmUsage.render_table(rows, period: period) unless rows.empty?
      tables << LlmUsage.render_token_table(token_rows) unless token_rows.empty?
      say tables.join("\n\n")
      notes.each { |note| say note, :gray }
    end
  end
end

task :wrap do
  desc <<~D
    Run a command with the last few prompts you typed pinned to the bottom of the screen.

    The command runs in a PTY that is shorter than the real terminal by the height of
    the bar, so those rows belong to the bar and nothing the program draws can cover
    them - no hooks, no tmux, no terminal-specific plumbing. Works with claude, codex,
    a REPL, a plain shell.

    The bar is a "prompt history" rule with the prompts below it, oldest first, so the
    newest one sits on the very last line. It is --lines + 1 rows tall.

    Each prompt gets one row: a multi-line prompt is flattened onto it with line breaks
    shown as a backslash, and the whole thing is clipped to the terminal width.

    A prompt is whatever you type between Enters. Shift/Option+Enter and pasted newlines
    keep appending to the current one. This is keystroke sniffing, so text the program
    inserts for you (history recall, autocomplete, menu picks) will not show up, and
    nothing is captured while the program has echo off in canonical mode (sudo, ssh).

    A line starting with ! is taken over: nothing reaches the wrapped program, the line
    runs in $SHELL here, and the bar grows to show where it ran, what ran and what it
    printed. That is a shell round trip instead of a tool call, a permission check and a
    model turn - and it costs no context either, since the agent is never told.

    Output stays up until you type anything at all, and a bare ! clears it too. Long
    output is cut to the rows there are, and a command still running after 10s is killed,
    since the wrapper is stopped while one runs. `cd` is handled here so that it sticks,
    and moves nothing but the wrapper. Type !! to send a literal ! to the program instead,
    which is how you reach Claude Code's own bash mode; a leading space does the same.

    Keys are decoded from plain bytes, the kitty keyboard protocol and xterm
    modifyOtherKeys, since a program can ask the terminal for any of the three (Claude
    Code turns on the last two). Mouse reports, focus events, arrows and Ctrl-<key> are
    not text and are dropped - including Ctrl-V, which pastes an image in Claude Code.

    LLM_WRAP_DEBUG=<file> logs what arrived and how it was read, for when a terminal
    reports keys in some way this does not know about. It records every keystroke.

    Put `--` before the wrapped command when it has flags of its own, otherwise they are
    parsed as flags to `llm wrap`.

    With no command at all, the commands in ~/.config/hammer/llm-wrap.txt are offered in
    an arrow-key picker instead. That file is plain text, one command per line. A line
    starting with # is dropped, and a line with no letter in it stays on screen but
    cannot be picked - so blanks and ---- rules group the list without being in the way.
    `--config` opens it in $EDITOR, writing a starting set the first time.
  D
  example 'wrap'
  example 'wrap --config'
  example 'wrap claude'
  example 'wrap -- claude --resume'
  example 'wrap --lines 5 -- bash -l'

  # `positional: false` is load-bearing: the parser fills un-set scalar opts
  # from positionals in declaration order, so without it `llm wrap claude`
  # would hand "claude" to --lines and die on the integer cast. `--config` is
  # boolean, which the parser skips over, so it needs no such guard.
  opt :lines, type: :integer, default: 3, positional: false,
              desc: 'how many recent prompts to pin', placeholder: 'N'
  opt :config, type: :boolean, desc: 'open the command list in $EDITOR'

  proc do |opts|
    # Required lazily - llm.rb also runs as a per-prompt hook (`llm prompt
    # hook`), which should not pay to load pty/io-console. `_llm_root` is a
    # local from the file scope; the block closes over it (instance_exec
    # rebinds self, not locals).
    require File.join(_llm_root, 'lib/llm/wrap')

    if opts[:config]
      editor = ENV['EDITOR'] || ENV['VISUAL']
      error '$EDITOR not set' unless editor
      say.green "created #{LlmWrap::Config.path}" if LlmWrap::Config.seed
      exit system(editor, LlmWrap::Config.path) ? 0 : 1
    end

    cmd = Array(opts[:args])

    # Nothing asked for: offer the list rather than a usage error. The picker
    # shows each line as it was written - re-joining a split argv would quote
    # it back differently from what is in the file.
    if cmd.empty?
      LlmWrap::Config.seed
      choices = LlmWrap::Config.lines
      unless choices.any? { |line| LlmWrap::Config.runnable?(line) }
        error "no commands in #{LlmWrap::Config.path} - add one with: llm wrap --config"
      end

      idx = choose('wrap which command?', choices, skip: ->(line) { !LlmWrap::Config.runnable?(line) })
      next say.gray('cancelled') unless idx

      cmd = LlmWrap::Config.argv(choices[idx])
    end

    # The wrapper renames itself after the program it runs, so that a pane
    # watcher can still see which agent is in there - which leaves nothing
    # behind that says how the pane was started. This is that: the invocation
    # rebuilt from what the parser gave us, since by then the real command line
    # is a resolved interpreter chain nobody typed. `--` keeps a wrapped
    # command's own flags out of our parser when it is read back.
    origin = ['llm', 'wrap', '--lines', opts[:lines].to_s, '--', *cmd]
    exit LlmWrap.run(cmd, keep: opts[:lines], origin:)
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
    example 'memory list'

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
    example 'memory read user-role'

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
    # :name first — the parser fills scalar opts from positionals in
    # declaration order, so without it `llm memory write foo --type=user`
    # lands "foo" in :description instead of the memory name.
    opt :name,        desc: 'memory name (slug)'
    opt :type,        desc: 'memory type (user|feedback|project|reference)', req: true
    opt :description, desc: 'one-line summary stored in frontmatter'

    proc do |opts|
      name = opts[:name]
      error 'usage: llm memory write <name> --type=<type> [--description="..."] < body' unless name
      error "unknown type: #{opts[:type]} (valid: #{VALID_TYPES.join(', ')})" unless VALID_TYPES.include?(opts[:type])

      # opts[:stdin], not $stdin.read — hammer drains piped stdin into opts
      # before the handler runs, so a direct read comes back empty.
      body = opts[:stdin].to_s
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
    example 'memory delete old-fact'

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
    example 'memory search react'

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

TODO_GUIDE ||= <<~TXT
  Per-project task queue in ./LLM_TODO.local.md - workable by humans and any agent.

  Human usage:
    llm todo:add "fix login redirect"   queue a task; pipe stdin for bulk:
                                        `* ` bullets delimit tasks (multi-line ok),
                                        no bullets at all = one task per line
    llm todo:list                       tasks by id, counts, format warnings
    llm todo:pop + llm todo:done        take / finish a single task by hand

    Edit the file freely: only the `# todo`, `# doing` and `# done` sections are
    managed. `# plan`, `# idea` and any prose stay untouched. A task starts with
    `*` at the line start and runs until the next `*` or header; when finished it
    moves to `# done` verbatim.

  LLM usage - one of these lines is the whole prompt:
    "Run `llm todo go` and follow its output."               work through every task
    "Run `llm todo pop`, do the task, run `llm todo done`."  do a single task

    Task text is printed raw on stdout. `todo go` repeats the protocol after each
    task and says when the queue is empty; `todo pop` re-prints the task in
    progress, so an interrupted agent resumes instead of skipping ahead.
TXT

task :todo do
  desc <<~D
    How the todo queue works, for humans and LLMs.

    #{TODO_GUIDE}
  D
  example 'todo'

  proc do
    say TODO_GUIDE
    say ''
    self.class.print_help 'todo:'
  end
end

namespace :todo do
  # Same story as :memory - helpers must live inside the namespace block.
  private

  TODO_FILE     ||= 'LLM_TODO.local.md'
  TODO_SECTIONS ||= { todo: 'todo', doing: 'doing', done: 'done' }.freeze

  def todo_path
    File.join(Dir.pwd, TODO_FILE)
  end

  # Exact title match on purpose - "# done ideas" must stay an unmanaged section.
  def todo_section_key(title)
    case title.strip.downcase
    when 'todo', 'pending'                     then :todo
    when 'doing', 'in progress', 'in-progress' then :doing
    when 'done', 'completed'                   then :done
    end
  end

  # The tool manages only the `# todo`, `# doing` and `# done` sections (any
  # heading level). Inside them a task starts at a `*` or `-` bullet in the
  # first column and runs until the next bullet or header, so tasks can span
  # multiple lines and move between sections verbatim. Every other section
  # (`# plan`, `# idea`, ...) and any preamble is kept as-is and never touched.
  # Returns [tasks, nodes]; nodes reproduce the document layout for todo_save.
  def todo_parse
    tasks = { todo: [], doing: [], done: [] }
    nodes = []
    return [tasks, nodes] unless File.file?(todo_path)

    section = nil # managed section key, nil while inside a raw chunk
    current = nil # lines of the task being collected

    flush_task = lambda do
      tasks[section] << current.join("\n").rstrip if current
      current = nil
    end

    File.foreach(todo_path) do |raw|
      line = raw.chomp
      if (m = line.match(/^#+\s*(\S.*?)\s*$/))
        flush_task.call
        section = todo_section_key(m[1])
        if section
          nodes << [:section, section] unless nodes.include?([:section, section])
        else
          nodes << [:raw, [line]]
        end
      elsif section
        if line =~ /^[-*]\s+(.*)$/
          flush_task.call
          current = [$1.strip]
        elsif current
          current << line.rstrip
        end
      else
        nodes << [:raw, []] unless nodes.last && nodes.last[0] == :raw
        nodes.last[1] << line.rstrip
      end
    end
    flush_task.call
    [tasks, nodes]
  end

  # Rewrite: managed sections in canonical form, raw chunks verbatim, original
  # order kept. Managed sections missing from the file are appended at the end.
  def todo_save(tasks, nodes)
    order = nodes + (TODO_SECTIONS.keys - nodes.map { |t, v| v if t == :section }).map { |k| [:section, k] }

    File.open(todo_path, 'w') do |io|
      order.each_with_index do |(type, value), i|
        io.puts unless i.zero?
        if type == :section
          io.puts "# #{TODO_SECTIONS[value]}"
          tasks[value].each do |text|
            io.puts
            io.puts "* #{text}"
          end
        else
          lines = value.dup
          lines.pop while lines.any? && lines.last.empty?
          lines.each { |l| io.puts l }
        end
      end
    end
  end

  # One-line label for confirmations - multi-line tasks show their first line.
  def todo_label(text)
    first, rest = text.split("\n", 2)
    rest ? "#{first} ..." : first
  end

  # Format sanity check for hand-edited files. Returns warning strings.
  def todo_lint(tasks)
    warns   = []
    seen    = Hash.new(0)
    section = :preamble
    File.foreach(todo_path) do |raw|
      line = raw.chomp
      if (m = line.match(/^#+\s*(\S.*?)\s*$/))
        key       = todo_section_key(m[1])
        section   = key || :other
        seen[key] += 1 if key
      elsif section == :preamble && line =~ /^[-*]\s/
        warns << "ignored bullet before any section header: #{line}"
      end
    end
    TODO_SECTIONS.each_key do |key|
      warns << "duplicate '# #{key}' sections - their tasks are merged" if seen[key] > 1
      warns << "missing '# #{key}' section - will be added on next write" if seen[key].zero?
    end
    warns << "#{tasks[:doing].length} tasks in doing - expected at most 1" if tasks[:doing].length > 1
    warns
  end

  task :add do
    desc <<~DESC
      Add task(s) to ./#{TODO_FILE} (created on first add).

      Text comes from the argument (one task), or from stdin. Piped input
      that has `*` / `-` bullets is a list: a bullet begins a task and the
      lines under it belong to it, so multi-line tasks and whole lists can be
      piped in at once. Input with no bullets at all is one task per line.
    DESC
    example 'todo add "migrate the user model to Sequel"'
    example 'cat tasks.md | llm todo add'
    opt :text, desc: 'task text (or pipe tasks on stdin)'

    proc do |opts|
      # unquoted multi-word input lands in :text + :args - join it back
      arg = [opts[:text], *opts[:args]].compact.join(' ').strip
      if arg.empty?
        lines     = opts[:stdin].to_s.split("\n")
        bulleted  = lines.any? { |l| l =~ /^[-*]\s+/ }
        new_tasks = []
        lines.each do |line|
          if line =~ /^[-*]\s+(.*)$/
            new_tasks << [$1.strip]
          elsif bulleted
            new_tasks.last << line.rstrip if new_tasks.any?
          elsif line.strip != ''
            new_tasks << [line.rstrip]
          end
        end
        new_tasks = new_tasks.map { |ls| ls.join("\n").rstrip }.reject(&:empty?)
      else
        new_tasks = [arg]
      end
      error 'usage: llm todo add <text> (or pipe tasks on stdin)' if new_tasks.empty?

      tasks, nodes = todo_parse
      tasks[:todo].concat new_tasks
      todo_save tasks, nodes
      new_tasks.each { |t| say "added: #{todo_label(t)}", :green }
    end
  end

  task :pop do
    desc <<~DESC
      Print the current task and stop there - one task, no loop.

      Moves the first todo task to doing if nothing is doing yet. Prints only
      the raw task text (agent-friendly stdout). Re-running without `todo done`
      prints the same task again, so an interrupted agent resumes instead of
      starting the next one. Exits 1 when the list is empty.
    DESC
    example 'todo pop'

    proc do
      tasks, nodes = todo_parse
      if tasks[:doing].empty?
        error 'todo list is empty' if tasks[:todo].empty?
        tasks[:doing] << tasks[:todo].shift
        todo_save tasks, nodes
      end
      puts tasks[:doing].first
    end
  end

  task :go do
    desc <<~DESC
      Agent entry point: work through the whole todo list.

      Prints the current task (pop) followed by the loop protocol, so telling
      any agent "run llm todo go" is enough to drain the queue. When the list
      is empty it says so and tells the agent to stop and summarize.
    DESC
    example 'todo go'

    proc do
      tasks, nodes = todo_parse
      if tasks[:doing].empty? && tasks[:todo].empty?
        say 'All tasks done - stop the loop and summarize what was done.'
        next
      end
      if tasks[:doing].empty?
        tasks[:doing] << tasks[:todo].shift
        todo_save tasks, nodes
      end
      say "TASK: #{tasks[:doing].first}"
      say ''
      say 'Do this task fully and verify it. Then run `llm todo done`, and `llm todo go` for the next one.'
    end
  end

  task :done do
    desc 'Mark the in-progress task as done'
    example 'todo done'

    proc do
      tasks, nodes = todo_parse
      error 'no task in progress (run: llm todo pop)' if tasks[:doing].empty?
      text = tasks[:doing].shift
      tasks[:done] << text
      todo_save tasks, nodes
      say "done: #{todo_label(text)}", :green
    end
  end

  task :list do
    alt :inspect
    desc 'Inspect the todo file: tasks by id, counts, format validity warnings'
    example 'todo list'

    proc do
      error "no #{TODO_FILE} in #{Dir.pwd} (run: llm todo add <text>)" unless File.file?(todo_path)
      tasks, = todo_parse
      id = 0
      TODO_SECTIONS.each do |key, title|
        say "#{title}:", :cyan
        color = { todo: nil, doing: :yellow, done: :gray }[key]
        tasks[key].each do |text|
          first, *rest = text.split("\n")
          say "#{(id += 1).to_s.rjust(3)}. #{first}", color
          rest.each { |l| say "     #{l}", color }
        end
        say '  (none)', :gray if tasks[key].empty?
      end
      say ''
      say "#{tasks[:todo].length} todo, #{tasks[:doing].length} doing, #{tasks[:done].length} done"
      todo_lint(tasks).each { |w| say "warning: #{w}", :yellow }
    end
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
    example 'prompt:expand :foo :bar'
    example 'prompt:expand foo:'

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

      raw = opts[:stdin].to_s
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

# The namespace's sibling task: `llm plan` explains the thing, `llm plan:*`
# does it. The command list underneath is hammer's own, not a copy.
task :plan do
  desc 'How the /plan bundle apply works: logic, bundle format, exit codes'
  example 'plan'

  proc do
    say LlmPlan.readme
    say ''
    self.class.print_help 'plan:'
  end
end

namespace :plan do
  # Helpers live inside the namespace block for the same reason as :memory -
  # a top-level `helpers do` lands on the root class, which namespaces do not
  # inherit from.
  private

  def load_bundle(opts)
    path = opts[:args].first
    error 'usage: llm plan:<apply|check|verify|revert> ./tmp/plan-[SLUG].json' unless path
    LlmPlan::Bundle.new(path)
  rescue LlmPlan::Error => e
    error e.message
  end

  # Hammer owns colour (and turns it off for a non-tty), so hand its painter
  # to the report rather than teaching the report about ANSI.
  def render(outcome)
    report = LlmPlan::Report.new(outcome, paint: Hammer::Shell.method(:paint))
    report.lines.each { |text, color| say text, color }
  end

  def run_verify(runner)
    result = runner.verify { |cmd| say "  > #{cmd}", :cyan }
    result.ok ? say('  verify ok', :green) : say("  FAIL #{result.failed_command}", :red)
    result
  end

  task :apply do
    # Composed from plan.md rather than written out again - see `llm plan`.
    desc ['Apply a /plan bundle: sha1-checked edits now, drift handed back to you.',
          "The bundle, normally ./tmp/plan-[SLUG].json:\n\n#{LlmPlan.section('The bundle')}",
          LlmPlan.section('Drift'),
          LlmPlan.section('Exit codes')].join("\n\n")
    example 'plan:apply ./tmp/plan-note-anchor.json'

    proc do |opts|
      bundle  = load_bundle(opts)
      runner  = LlmPlan::Runner.new(bundle)
      outcome = runner.apply

      render outcome
      outcome.verify = run_verify(runner) if outcome.clean?

      exit outcome.exit_code
    end
  end

  task :check do
    desc ['Dry run: the summary to read before approving a plan. Writes nothing.',
          LlmPlan.section('Summary')].join("\n\n")
    example 'plan:check ./tmp/plan-note-anchor.json'
    example 'plan:check --md ./tmp/plan-note-anchor.json'

    opt :md, type: :boolean, desc: 'emit the summary as markdown, to paste into a reply'

    proc do |opts|
      outcome = LlmPlan::Runner.new(load_bundle(opts)).apply(check_only: true)
      opts[:md] ? puts(LlmPlan::MarkdownReport.new(outcome).to_s) : render(outcome)
      exit outcome.exit_code
    end
  end

  task :verify do
    desc <<~D
      Run only the bundle's verify commands.

      For after you have closed a drift by hand, or fixed what a failing verify
      caught. Exit 0 green, 20 failed.
    D
    example 'plan:verify ./tmp/plan-note-anchor.json'

    proc do |opts|
      exit run_verify(LlmPlan::Runner.new(load_bundle(opts))).ok ? 0 : 20
    end
  end

  task :revert do
    desc 'Undo an applied bundle from <slug>.bak: restore changed and deleted files, remove created ones.'
    example 'plan:revert ./tmp/plan-note-anchor.json'

    proc do |opts|
      LlmPlan::Runner.new(load_bundle(opts)).revert.each { |path| say "  restored #{path}", :green }
    rescue LlmPlan::Error => e
      error e.message
    end
  end
end

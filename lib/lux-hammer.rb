require_relative 'hammer/shell'
require_relative 'hammer/option'
require_relative 'hammer/parser'
require_relative 'hammer/command'
require_relative 'hammer/cron'
require_relative 'hammer/loader'
require_relative 'hammer/builder'
require_relative 'hammer/command_builder'
require_relative 'hammer/dotenv'
require_relative 'hammer/recipe'

# Thor-inspired tiny CLI builder.
#
# Class DSL:
#
#   class MyCli < Hammer
#     task :build do
#       desc    'Build the project'
#       example 'build -v --env=prod'
#       opt :verbose, type: :boolean, alias: :v
#       opt :env,     type: :string,  default: 'dev'
#       proc do |opts|
#         say.green "building #{opts[:env]} args=#{opts[:args].inspect}"
#       end
#     end
#   end
#
#   MyCli.start(ARGV)
#
# Block DSL is identical, just inside `Hammer.run`:
#
#   Hammer.run(ARGV) do
#     task :hello do
#       desc 'Greet someone'
#       opt :loud, type: :boolean, alias: :l
#       proc do |opts|
#         msg = "hello #{opts[:args].first || 'world'}"
#         msg = msg.upcase if opts[:loud]
#         say msg, :cyan
#       end
#     end
#   end
class Hammer
  include Shell

  Error          ||= Class.new(StandardError)
  AmbiguousMatch ||= Class.new(Error)

  # Gem version, read once from the bundled .version file.
  VERSION ||= File.read(File.expand_path('../.version', __dir__)).strip

  class << self
    def inherited(sub)
      super
      sub.instance_variable_set(:@commands, {})
      sub.instance_variable_set(:@namespaces, {})
      sub.instance_variable_set(:@before_hooks, [])
      sub.instance_variable_set(:@parent, nil)
      sub.instance_variable_set(:@program_name, nil)
      sub.instance_variable_set(:@app_desc, nil)
      sub.instance_variable_set(:@pending_desc, nil)
      sub.instance_variable_set(:@pending_examples, [])
      sub.instance_variable_set(:@pending_options, [])
      sub.instance_variable_set(:@pending_alts, [])
      sub.instance_variable_set(:@pending_needs, [])
      sub.instance_variable_set(:@pending_cron, nil)
    end

    # ----- class-level DSL for `def`-style commands ---------------------
    # Set pending metadata that the next `def` will consume.
    #
    #   class MyCli < Hammer
    #     desc 'Build'
    #     opt :env, default: 'dev'
    #     def build(opts)
    #       say "building #{opts[:env]}"
    #     end
    #   end

    def desc(text)       ; @pending_desc = text.to_s.rstrip end
    def example(text)    ; @pending_examples << text end
    def opt(name, **o)   ; @pending_options << Option.new(name, **o) end
    def alt(*names)      ; @pending_alts.concat(names) end
    def needs(*names)    ; @pending_needs.concat(names) end
    def cron(expr)       ; @pending_cron = expr end

    def method_added(method_name)
      super
      return unless @pending_desc

      cmd = Command.new(name: method_name.to_s, desc: @pending_desc)
      @pending_examples.each { |e| cmd.add_example(e) }
      @pending_options.each  { |o| cmd.add_option(o) }
      @pending_alts.each     { |n| cmd.add_alt(n) }
      @pending_needs.each    { |n| cmd.add_need(n) }
      cmd.set_cron(@pending_cron) if @pending_cron

      # If the method takes no args, call it without opts. Otherwise pass
      # opts. So both `def build` and `def build(opts)` work.
      m = method_name
      takes_arg = instance_method(method_name).parameters.any? { |type, _| %i[req opt rest].include?(type) }
      cmd.handler = takes_arg ? proc { |opts| send(m, opts) } : proc { send(m) }
      cmd.finalize!
      commands[cmd.name] = cmd

      @pending_desc = nil
      @pending_examples = []
      @pending_options  = []
      @pending_alts     = []
      @pending_needs    = []
      @pending_cron     = nil
    end

    # Resolved lazily on first read and memoized, so callers that need the
    # cwd-relative form (see `default_program_name`) can warm the cache
    # before chdir-ing elsewhere.
    def program_name
      @program_name ||= default_program_name
    end

    # Top-level description for the whole CLI. Set from a Hammerfile (block
    # DSL) via `desc 'text'` at top level - see `Hammer::Builder#desc`.
    # Rendered under the Usage line in `--help` output.
    def app_desc(text = nil)
      return @app_desc if text.nil?
      @app_desc = text.to_s.rstrip
    end

    # Program name shown in help/usage: the invocation path relative to cwd
    # if the script lives inside it (e.g. `bin/foo` when invoked from the
    # project root), otherwise the basename (e.g. `lux` for a globally
    # installed bin in PATH).
    def default_program_name
      prog = $PROGRAM_NAME
      return File.basename(prog) unless prog.include?('/')
      # Resolve symlinks on both sides so e.g. macOS `/tmp` -> `/private/tmp`
      # doesn't cause a false miss when comparing prefixes.
      abs = File.realpath(prog) rescue File.expand_path(prog)
      cwd = File.realpath(Dir.pwd) rescue Dir.pwd
      return abs[(cwd.length + 1)..] if abs.start_with?("#{cwd}/")
      File.basename(prog)
    end

    # Define a command. Block runs in a CommandBuilder context and must
    # return a Proc as its last expression. That proc is the handler and
    # receives a single `opts` hash with symbol keys; positional ARGV
    # lives at `opts[:args]`.
    def task(name, &block)
      cmd = Command.new(name: name.to_s)
      cmd.location = source_location_of(block)
      handler = CommandBuilder.new(cmd).instance_eval(&block)
      unless handler.is_a?(Proc)
        raise Error, <<~MSG
          task(:#{name}) block must end with a `proc do |opts| ... end`.
          The proc's return value is what becomes the command handler.

          Example:

            task :#{name} do
              desc    'what it does'
              example '#{name} foo --env=prod'
              opt :env, default: 'dev'

              proc do |opts|
                # your code here - opts[:env], opts[:args], ...
              end
            end
        MSG
      end
      cmd.handler = handler

      # Only warn when overriding a task that was also defined inside the
      # main app. Overriding one that came from outside - a framework
      # default, plugin, or gem - is an intentional override, so stay quiet
      # and don't tag it `(redefined)` in help.
      if (prev = commands[cmd.name]) && app_local_location?(prev.location)
        cmd.prev_location = prev.location
        warn_redefinition('task', cmd.name, prev.location, cmd.location)
      end

      cmd.finalize!
      commands[cmd.name] = cmd

      # `task` ignores pending class-level state, but clear it so a
      # later `def` doesn't accidentally consume stale metadata.
      @pending_desc = nil
      @pending_examples = []
      @pending_options  = []
      @pending_alts     = []
      @pending_needs    = []
      @pending_cron     = nil
    end

    # Open a namespace (group of commands). Everything inside the block
    # (task, nested namespace, ...) belongs to that namespace, evaluated
    # against an anonymous Hammer subclass.
    #
    #   namespace :db do
    #     task :migrate do ... end
    #     namespace :users do ... end
    #   end
    #
    # Reopening a namespace merges: the same `namespace :db do ... end` can
    # be split across files (Rake-style) and the blocks accumulate onto one
    # subclass. Only a duplicate *task* name inside warns - that's handled
    # by `task`. The namespace subclass is created lazily on first mention.
    def namespace(name, &block)
      sub = (@namespaces[name.to_s] ||= begin
        ns = Class.new(Hammer)
        # Track the top-level CLI class so cross-invocation
        # (`hammer 'ns:cmd'`) from inside a namespaced command dispatches
        # against the full tree, not just the current namespace.
        ns.instance_variable_set(:@root, root)
        # Parent link, so `before` hooks defined further up the namespace
        # tree can be collected and run outer -> inner before a command.
        ns.instance_variable_set(:@parent, self)
        # Share the parent's resolved program_name so help banners show
        # "myapp ns:cmd" with the same prefix everywhere - and so the value
        # captured pre-chdir (see `Hammer.cli`) survives into nested classes.
        ns.instance_variable_set(:@program_name, program_name)
        ns.instance_variable_set(:@location, source_location_of(block))
        ns
      end)

      Hammer.with_target(sub) { sub.class_eval(&block) } if block
    end

    # Register a hook to run before every command in this class (root or
    # namespace). Hooks receive the command's `opts` hash. All hooks run
    # outer -> inner, once per top-level `start` (prereqs don't re-trigger).
    #
    #   before { |opts| Dotenv.load }
    #   namespace :db do
    #     before { hammer :env }
    #     task :migrate do ... end
    #   end
    def before(&block)
      before_hooks << block
    end

    def before_hooks
      @before_hooks
    end

    # Toggle auto-loading of `.env` / `.env.local` for the `hammer`
    # binary. Default is ON. Call `dotenv false` at the top of a
    # Hammerfile to suppress. No-op for standalone `MyCli.start` -
    # auto-load only fires from `Hammer.cli`.
    def dotenv(flag = true)
      @dotenv_enabled = flag
    end

    def dotenv_enabled?
      @dotenv_enabled != false
    end

    def parent
      @parent
    end

    # "file:line" of the block that defined a task/namespace. Falls back
    # to "(unknown)" for blocks without a usable source_location (rare -
    # built-in C-defined procs, eval'd blocks).
    def source_location_of(block)
      loc = block&.source_location
      loc ? "#{relativize_path(loc[0])}:#{loc[1]}" : '(unknown)'
    end

    # Trim the cwd prefix off an absolute path so redefinition warnings
    # read as `./lib/tasks/foo.rb` instead of a long absolute path. Paths
    # outside cwd (framework / gem files) are left absolute.
    def relativize_path(path)
      prefix = "#{Dir.pwd}/"
      path.start_with?(prefix) ? ".#{path[Dir.pwd.length..]}" : path
    end

    # True when a captured location lives inside the main app. relativize_path
    # rewrites in-app absolute paths to a `.`-relative form, so anything still
    # starting with "/" is an absolute path outside cwd - a framework, plugin,
    # or gem file. Relative locations are already cwd-anchored, hence local.
    def app_local_location?(loc)
      !loc.to_s.start_with?('/')
    end

    # Emit a yellow [hammer] warning on stderr when a task/namespace is
    # redefined. Last write wins (commands[name] = cmd), but the prior
    # location is captured so listings can tag the entry as `(redefined)`.
    def warn_redefinition(kind, name, prev_loc, new_loc)
      warn Shell.paint("[hammer] redefined #{kind} :#{name} - was #{prev_loc || '(unknown)'}, now #{new_loc || '(unknown)'}", :yellow)
    end

    # Root -> ... -> self. Used to gather `before` hooks for a command.
    def ancestor_chain
      chain = []
      klass = self
      while klass
        chain.unshift klass
        klass = klass.parent
      end
      chain
    end

    # Topmost class in this CLI tree. For user-defined `class MyCli < Hammer`
    # or `Class.new(Hammer)` it's self; for namespace subclasses it's
    # whichever class opened the namespace.
    def root
      @root || self
    end

    def commands
      @commands ||= {}
    end

    def namespaces
      @namespaces ||= {}
    end

    # Per-target Loader instance. Owns the dedup cache, so re-entrant
    # `load` from inside a fragment is safe and idempotent.
    def loader
      @loader ||= Loader.new(self)
    end

    # Push `klass` as the current Hammer target for the duration of the
    # block. Top-level DSL methods (`task`, `namespace`, `before` - see
    # `Hammer::DSL`) read this thread-local, so files `require`d from
    # inside a Hammerfile register against the right target.
    def with_target(klass)
      prev = Thread.current[:hammer_target]
      Thread.current[:hammer_target] = klass
      yield
    ensure
      Thread.current[:hammer_target] = prev
    end

    # Load Hammerfile fragments and register their commands on this
    # class. Rake-style: split a CLI across multiple files.
    #
    #   load                        # auto-discover *_hammer.rb under caller dir
    #   load auto: true             # same
    #   load 'tasks/db_hammer.rb'   # one file
    #   load 'tasks/*_hammer.rb'    # glob
    #
    # Paths resolve relative to the file calling `load`. See
    # `Hammer::Loader` for the full implementation.
    def load(*paths, **kwargs)
      if self == Hammer
        raise Error, 'use `load` from inside a Hammerfile / Hammer.run block / Hammer subclass body, ' \
                     'or call SubClass.load - Hammer.load itself has no target'
      end
      anchor = Loader.caller_anchor(caller_locations(1, 1).first)
      loader.load(anchor, paths, kwargs)
    end

    # Entry point. Parses ARGV, finds the right command, runs it.
    # Command names are Rake-style colon paths: "build", "db:migrate",
    # "db:users:list".
    #
    # Rake-style chained dispatch: `hammer build + deploy + notify`.
    # A bare `+` argv token separates commands; `++` escapes to a literal
    # `+` positional. Quoted shell args (`--foo="a + b"`) arrive as a
    # single token and are not split.
    def start(argv = ARGV)
      # Track prereqs fired during this top-level invocation so a `needs`
      # chain runs each prereq at most once. Nested `start` calls (e.g.
      # `needs` -> `hammer` -> `start`, or a `+` chain) share the set;
      # the outermost call owns its lifetime.
      outer = Thread.current[:hammer_needs_ran].nil?
      Thread.current[:hammer_needs_ran] ||= {}
      Thread.current[:hammer_before_ran] ||= {}

      split_chain(argv).each { |seg| dispatch(seg) }
    ensure
      Thread.current[:hammer_needs_ran] = nil if outer
      Thread.current[:hammer_before_ran] = nil if outer
    end

    private

    # Split argv on bare `+` tokens; unescape `++` -> `+` within each
    # segment. Returns [argv] when no chain operator is present.
    def split_chain(argv)
      return [argv] unless argv.include?('+') || argv.include?('++')
      segs = argv.slice_when { |a, b| a == '+' || b == '+' }
                 .map { |seg| seg.reject { |t| t == '+' } }
                 .map { |seg| seg.map { |t| t == '++' ? '+' : t } }
                 .reject(&:empty?)
      segs.empty? ? [argv] : segs
    end

    # Run a single (already-split) command segment.
    def dispatch(argv)
      argv = argv.dup
      name = argv.shift

      # Bare invocation OR leading flag (other than -h/--help) -> :default
      # task. Re-prepend the flag so :default's option parser sees it.
      # If no :default is defined, fall back to top-level help.
      if name.nil? || (name.start_with?('-') && name != '-h' && name != '--help')
        argv.unshift(name) if name
        return dispatch_to_builtin('default', argv) { print_help }
      end

      # Explicit help requests -> :help task. Remaining positionals (e.g.
      # `help build`, `help db:`) reach :help via opts[:args].
      if name == 'help' || name == '-h' || name == '--help'
        return dispatch_to_builtin('help', argv) { print_help(argv.first, extended: true) }
      end

      # Trailing colon ("db:") -> namespace listing. Bare ":" lists root.
      if name.end_with?(':') && name != ':'
        bare = name.chomp(':')
        ns, canonical = resolve_namespace(bare)
        return print_namespace_help(canonical, ns) if ns
        Shell.print_error("unknown namespace: #{bare}")
        print_help
        exit 1
      elsif name == ':'
        return print_help
      end

      # An exact namespace beats a fuzzy command match, so `hammer h` lists
      # the `h:` namespace instead of prefix-matching some `h...` command.
      if !commands.key?(name) && namespaces.key?(name)
        ns, canonical = resolve_namespace(name)
        return print_namespace_help(canonical, ns)
      end

      cmd, owner, canonical = resolve(name)
      return owner.run_command(cmd, argv, full: canonical) if cmd

      ns, canonical = resolve_namespace(name)
      return print_namespace_help(canonical, ns) if ns

      Shell.print_error("unknown command: #{name}")
      print_help
      exit 1
    rescue AmbiguousMatch => e
      Shell.print_error(e.message)
      exit 1
    end

    # Run a built-in routing task (:default or :help) if defined,
    # otherwise yield to the fallback block. The implicit run banner
    # is suppressed (the user typed `hammer --version`, not `hammer
    # default --version` - no point echoing the rewritten form).
    def dispatch_to_builtin(name, argv)
      cmd = commands[name]
      return yield unless cmd
      run_command(cmd, argv, full: name, quiet: true)
    end

    # True when -h or --help appears in argv before a `--` stop-marker.
    def help_requested?(argv)
      stop = argv.index('--')
      scan = stop ? argv[0...stop] : argv
      scan.include?('-h') || scan.include?('--help')
    end

    public

    # Find a command by canonical name or alt within this class. Falls
    # back to fuzzy match (prefix first, then substring) when no exact
    # hit. Raises AmbiguousMatch if the fuzzy pass matches more than one.
    def find_command(name)
      name = name.to_s
      exact = commands[name] || commands.values.find { |c| c.matches?(name) }
      return exact if exact
      fuzzy_pick(name, commands.values, 'command') { |c| [c.name, *c.alts] }
    end

    # Find a namespace by name within this class. Same fuzzy fallback
    # as find_command.
    def find_namespace(name)
      name = name.to_s
      return namespaces[name] if namespaces.key?(name)
      pair = fuzzy_pick(name, namespaces.to_a, 'namespace') { |p| [p.first] }
      pair&.last
    end

    # Returns the command at the parent that shares its name with this
    # namespace. E.g. for path "gem:version" returns the `version` command
    # in the `gem` namespace (if defined), so `gem:version:` listings can
    # include `gem:version` itself at the top.
    def find_namespace_sibling(canonical)
      parts = canonical.to_s.split(':')
      return nil if parts.empty?
      parent = self
      parts[0..-2].each do |seg|
        parent = parent.namespaces[seg] or return nil
      end
      parent.commands[parts.last]
    end

    # Walk "ns1:ns2:cmd" -> [command, owning_class, canonical_path].
    # Returns [nil, nil, nil] if any segment is missing or the final
    # segment isn't a command. canonical_path uses the canonical name
    # of every segment (so a fuzzy `b` resolves to `build` in the path).
    def resolve(path)
      parts = path.to_s.split(':')
      klass = self
      canonical = []
      parts[0..-2].each do |ns|
        sub = klass.find_namespace(ns) or return [nil, nil, nil]
        canonical << klass.namespaces.key(sub)
        klass = sub
      end
      cmd = klass.find_command(parts.last)
      return [nil, nil, nil] unless cmd
      canonical << cmd.name
      [cmd, klass, canonical.join(':')]
    end

    # Walk "ns1:ns2" -> [namespace_class, canonical_path].
    # Returns [nil, nil] if any segment is missing.
    def resolve_namespace(path)
      parts = path.to_s.split(':')
      klass = self
      canonical = []
      parts.each do |ns|
        sub = klass.find_namespace(ns) or return [nil, nil]
        canonical << klass.namespaces.key(sub)
        klass = sub
      end
      [klass, canonical.join(':')]
    end

    # Shared fuzzy matcher used by find_command and find_namespace.
    # The block returns the strings to match against for each item
    # (canonical name plus alts for commands, just the key for namespaces).
    # Tries prefix match first, then substring; raises AmbiguousMatch
    # when either pass hits more than one item.
    def fuzzy_pick(name, items, kind, &keys_for)
      return nil if name.empty?
      [:start_with?, :include?].each do |op|
        matches = items.select { |item| keys_for.call(item).any? { |k| k.send(op, name) } }
        next if matches.empty?
        if matches.size > 1
          labels = matches.map { |m| keys_for.call(m).first }.sort
          raise AmbiguousMatch, "multiple #{kind}s match '#{name}': #{labels.join(', ')}"
        end
        return matches.first
      end
      nil
    end

    # Programmatic dispatch by name. Useful for scripting and tests.
    #
    #   MyCli.hammer :build                       -> start(["build"])
    #   MyCli.hammer 'db:users:list'              -> start(["db:users:list"])
    #   MyCli.hammer :eval, 'puts 42'             -> start(["eval", "puts 42"])
    #   MyCli.hammer :build, env: 'prod'          -> start(["build", "--env=prod"])
    #   MyCli.hammer :build, verbose: true        -> start(["build", "--verbose"])
    #   MyCli.hammer :build, no_cache: true       -> start(["build", "--no-cache"])
    #   MyCli.hammer :build, cache: false         -> skipped (no-op)
    #
    # Symbols are single-segment names; pass a string with colons for
    # namespaced paths. Trailing positionals become positional ARGV.
    # Underscores in option keys become dashes in flags.
    def hammer(name, *args, **opts)
      argv = [name.to_s, *args.map(&:to_s)]
      opts.each do |k, v|
        next if v == false
        flag = "--#{k.to_s.tr('_', '-')}"
        if v == true
          argv << flag
        else
          argv << "#{flag}=#{v.is_a?(Array) ? v.join(',') : v}"
        end
      end
      start(argv)
    end

    # Yield [full_colon_path, Command] for every command in this class
    # and all nested namespaces. `include_builtins: false` prunes
    # namespaces flagged `@builtin_namespace` (the reserved `h:` tree) -
    # used so the compact listing hides built-ins outside `--help`. Only
    # affects descent from a parent; iterating a flagged namespace
    # directly (e.g. `hammer h:`) still lists its own commands.
    def each_command(prefix = nil, include_builtins: true, &block)
      commands.each_value do |c|
        full = prefix ? "#{prefix}:#{c.name}" : c.name
        yield full, c
      end
      namespaces.each do |ns_name, sub|
        next if !include_builtins && sub.instance_variable_get(:@builtin_namespace)
        sub_prefix = prefix ? "#{prefix}:#{ns_name}" : ns_name
        sub.each_command(sub_prefix, include_builtins: include_builtins, &block)
      end
    end

    # Machine-readable spec for `h:json` -> the macOS GUI (and, later,
    # for lux itself to render the default listing). One hash:
    #   commands => { group => { full_path => task_meta } }
    # Grouping/sort mirror the bare-`hammer` listing exactly: group by
    # the first namespace segment (a bare task sharing a namespace's name
    # joins that group via section_for), root tasks under "__root",
    # "__root" first, remaining groups in first-encounter order, tasks
    # within a group by [depth, name]. Hidden (no-`desc`) tasks are
    # skipped and the reserved `h:` tree is pruned unless include_builtins.
    def export_spec(include_builtins: false)
      groups = {}   # group => { full_path => meta }, in first-encounter order

      each_command(include_builtins: include_builtins) do |path, c|
        next if c.desc.empty?
        section = section_for(path, nil, self)
        key = section == :root ? '__root' : section.to_s
        (groups[key] ||= {})[path] = c.to_h(path)
      end

      sort_tasks = ->(h) { h.sort_by { |p, _| [p.count(':'), p] }.to_h }
      ordered = {}
      ordered['__root'] = sort_tasks.call(groups.delete('__root')) if groups.key?('__root')
      groups.each { |k, v| ordered[k] = sort_tasks.call(v) }

      {
        schema:         1,
        hammer_version: VERSION,
        program_name:   program_name,
        app_desc:       app_desc,
        commands:       ordered
      }
    end

    def run_command(cmd, argv, full: nil, quiet: false)
      # -h / --help is reserved on every command. Anywhere before a `--`
      # stop-marker, it short-circuits to per-command help.
      return print_command_help(cmd, full) if help_requested?(argv)

      positional, opts = Parser.new(cmd.options).parse(argv)
      opts[:args] = positional
      print_run_banner(cmd, full || cmd.name, positional, opts) unless quiet || ENV['HAMMER_QUIET']
      instance = new
      run_before_hooks(instance, opts)
      run_needs(cmd)
      instance.instance_exec(opts, &cmd.handler)
    rescue Parser::Error => e
      Shell.print_error(e.message)
      print_command_help(cmd, full)
      exit 1
    rescue Hammer::Error => e
      # Raised by `error 'msg'` inside a handler - controlled exit, no
      # backtrace, no per-command help spam.
      Shell.print_error(e.message)
      exit 1
    end

    # Print a gray "> prog cmd --opt=val ARG" banner before a command
    # runs. Helps see what was actually picked when fuzzy matching
    # resolved a partial name. Only opts that differ from their default
    # are shown; booleans render as `--flag` / `--no-flag`.
    def print_run_banner(cmd, full, positional, opts)
      parts = ["#{program_name} #{full}"]
      cmd.options.each do |o|
        val = opts[o.name]
        next if val.nil? || val == o.default
        if o.boolean?
          parts << (val ? "--#{o.name}" : "--no-#{o.name}")
        else
          parts << "--#{o.name}=#{val.is_a?(Array) ? val.join(',') : val}"
        end
      end
      parts.concat(positional)
      # Diagnostic, not program output - to stderr so stdout stays clean
      # for machine-readable tasks (`h:json`, `h:version`) and pipes.
      warn Shell.paint("> #{parts.join(' ')}", :gray)
    end

    # Fire `before` hooks from root down through the namespace chain.
    # Each class's hooks fire at most once per top-level `start`, so
    # prereqs dispatched via `needs` won't re-trigger them.
    def run_before_hooks(instance, opts)
      # Built-in `h:` meta-commands parent to the project root but must not
      # trigger the project's own `before` hooks (dotenv, env checks, ...).
      return if instance_variable_get(:@builtin_namespace)
      ran = Thread.current[:hammer_before_ran] ||= {}
      ancestor_chain.each do |klass|
        next if ran[klass.object_id]
        ran[klass.object_id] = true
        klass.before_hooks.each { |hook| instance.instance_exec(opts, &hook) }
      end
    end

    # Dispatch a command's declared `needs` through the root class, with
    # per-invocation dedupe. Prereqs run with default options (no argv).
    def run_needs(cmd)
      return if cmd.needs.empty?
      ran = Thread.current[:hammer_needs_ran] ||= {}
      cmd.needs.each do |path|
        key = path.to_s
        next if ran[key]
        ran[key] = true
        target, = root.resolve(key)
        raise Error, "needs: unknown command '#{key}' in #{cmd.name}" unless target
        root.start([key])
      end
    end

    public

    # `extended: true` is the verbose `help` / `-h` / `--help` form -
    # appends global flags, the GitHub footer, and (for the hammer binary)
    # a Hammerfile example. Bare invocation passes `extended: false` so
    # the no-args output stays a clean command listing.
    def print_help(target = nil, expanded: false, extended: false)
      if target
        # `help ns:` is equivalent to `ns:` - namespace listing.
        if target.end_with?(':') && target != ':'
          bare = target.chomp(':')
          ns, canonical = resolve_namespace(bare)
          return print_namespace_help(canonical, ns) if ns
          Shell.print_error("unknown: #{target}")
          return
        end
        cmd, _, canonical = resolve(target)
        return print_command_help(cmd, canonical) if cmd
        ns, canonical = resolve_namespace(target)
        return print_namespace_help(canonical, ns, expanded: expanded) if ns
        Shell.print_error("unknown: #{target}")
        return
      end

      print_top_banner
      Shell.say "Usage: #{program_name} COMMAND [ARGS]", :cyan
      # Compact (bare-invocation) view only - the extended `--help` view
      # already IS the full usage, so don't nag about it there.
      unless extended
        Shell.say "add `--help` to show usage help", :gray
        # No project Hammerfile + no custom tasks loaded: point the user at
        # `h:init`. The flag is set by `Hammer.cli` when the lookup misses.
        if instance_variable_get(:@no_hammerfile)
          Shell.say "no Hammerfile found in #{Dir.pwd} - run `#{program_name} h:init` to create one", :gray
        end
      end
      if @app_desc && !@app_desc.empty?
        Shell.say ''
        @app_desc.each_line { |l| Shell.say "  #{l.chomp}" }
      end
      # Built-in `h:` commands only surface in the extended view
      # (`--help` / `-h` / `help`); the bare-invocation listing stays
      # focused on the project's own tasks. They remain dispatchable
      # regardless - this only governs what the listing shows.
      if expanded
        each_command(include_builtins: extended) { |path, c| print_full_block(path, c) unless c.desc.empty? }
      else
        Shell.say ''
        print_command_list(include_builtins: extended)
      end
      print_recipes_section if extended && root.instance_variable_get(:@hammer_binary)
      print_extras if extended
    end

    # Lists recipes (gem + user-dir) under their own section in
    # `hammer --help`. Each row shows the recipe's `# desc:` line and
    # either an install hint or the path of the existing stub on PATH.
    # Only rendered when this CLI is the `hammer` binary's root.
    def print_recipes_section
      entries = Hammer::Recipe.all
      return if entries.empty?
      Shell.say ''
      Shell.say 'Recipes:', :yellow
      width = entries.keys.map(&:length).max
      entries.each do |name, file|
        desc = Hammer::Recipe.desc(file)
        installed = Hammer::Recipe.installed_path(name)
        suffix = installed ? "(installed: #{installed})" : "[install: #{program_name} h:recipes --install #{name}]"
        Shell.say "  #{name.ljust(width)}  # #{desc}"
        Shell.say "  #{' ' * width}    #{suffix}", :gray
      end
    end

    # `extended:` is accepted for parity with `print_help` but intentionally
    # not used here - the global-flags / Hammerfile-example / footer block
    # is root-help-only. `expanded:` is also accepted for parity; a namespace
    # listing is always the compact command list.
    def print_namespace_help(prefix, ns, expanded: false, extended: false)
      Shell.say "Usage: #{program_name} #{prefix}:COMMAND [ARGS]", :cyan
      rows = []
      sibling = find_namespace_sibling(prefix)
      rows << [prefix, sibling.to_h(prefix)] if sibling && !sibling.desc.empty?
      ns.each_command(prefix) { |path, c| rows << [path, c.to_h(path)] unless c.desc.empty? }
      unless rows.empty?
        Shell.say ''
        Shell.say 'Commands:', :yellow
        width = rows.map { |path, _| path.length }.max
        emit_rows(rows.sort_by { |path, _| [path.count(':'), path] }, width)
      end
    end

    # One "task block" for the expanded listing: blank line separator
    # then the standard per-command help (usage + desc + options + examples).
    def print_full_block(path, cmd)
      Shell.say ''
      print_command_help(cmd, path)
    end

    HOMEPAGE ||= 'https://github.com/dux/hammer'.freeze

    # Gray "lux-hammer X.Y.Z - <homepage>" line shown above top-level help
    # in both bare-invocation and `--help` modes, so the link is always
    # one glance away. User CLIs skip it (the lux-hammer name/link is
    # irrelevant outside the `hammer` binary).
    def print_top_banner
      return unless root.instance_variable_get(:@hammer_binary)
      Shell.say "lux-hammer #{VERSION} - #{HOMEPAGE}", :gray
      Shell.say ''
    end

    # Extras shown only in the extended (`help` / `-h` / `--help`) view:
    # global flags, GitHub footer, and a Hammerfile example for the
    # `hammer` binary. The footer is skipped for the hammer binary
    # because `print_top_banner` already surfaces the same link.
    def print_extras
      hammer_bin = root.instance_variable_get(:@hammer_binary)
      print_global_flags
      print_hammerfile_example if hammer_bin
      print_footer unless hammer_bin
    end

    # Listed under `Default task options:` in `--help` so users see what
    # flags fire on bare-flag invocation (`hammer --version` etc).
    # Re-rendered from the live `:default` task so user-defined
    # overrides surface their own flags here automatically.
    def print_global_flags
      default = root.commands['default']
      return unless default && !default.options.empty?
      Shell.say ''
      Shell.say 'Default task options:', :yellow
      default.options.each { |o| Shell.say "  #{o.usage}" }
    end

    def print_footer
      Shell.say ''
      Shell.say "powered by hammer (v#{VERSION}) - #{HOMEPAGE}", :gray
    end

    # Hammerfile cheat-sheet shown under `hammer --help`. Same content
    # as `hammer --init` writes - single source of truth via
    # `Hammer::STARTER_HAMMERFILE`. For exhaustive docs see `hammer h:agents`.
    def print_hammerfile_example
      Shell.say ''
      Shell.say 'Hammerfile example:', :yellow
      Shell.say Hammer::STARTER_HAMMERFILE
    end

    # Pure rendering off `export_spec` - the same grouped structure
    # `h:json` emits, so the listing and the JSON can never drift.
    # `export_spec` already does the work: drops hidden (no-`desc`)
    # tasks, prunes the `h:` tree unless include_builtins, groups by
    # first namespace segment ("__root" for bare tasks), orders "__root"
    # first, and sorts each group by [depth, name].
    def print_command_list(include_builtins: true)
      groups = export_spec(include_builtins: include_builtins)[:commands]
      return if groups.empty?

      width = groups.values.flat_map(&:keys).map(&:length).max
      groups.each_with_index do |(section, tasks), i|
        Shell.say unless i.zero?
        Shell.say(section == '__root' ? 'Commands:' : "#{section}:", :yellow)
        emit_rows(tasks.to_a, width)
      end
    end

    # `rows` is an array of [full_path, task_meta] - the per-task hashes
    # from `Command#to_h` (also used to render namespace listings).
    def emit_rows(rows, width)
      rows.each do |full, t|
        brief = t[:alts].empty? ? t[:brief] : "#{t[:brief]} (alt: #{t[:alts].join(', ')})"
        brief = "#{brief} #{Shell.paint('(redefined)', :yellow)}" if t[:redefined]
        Shell.say "  #{program_name} #{full.ljust(width)}  # #{brief}"
      end
    end

    # 'db' for 'db:migrate' or 'db:users:list' viewed from root; 'users'
    # for 'db:users:list' viewed from 'db'; :root if the command sits at
    # the view's top level. Only the first segment under the view groups,
    # so deeper paths fold into their top-level section.
    #
    # Exception: a bare command that shares its name with a sibling
    # namespace (e.g. `mount` alongside a `mount:` namespace) groups
    # under that namespace's section, not :root.
    def section_for(full, prefix, klass = nil)
      segs = full.split(':')
      segs = segs[prefix.split(':').size..] || [] if prefix && !prefix.empty?
      if segs.size == 1 && klass && klass.namespaces.key?(segs.first)
        return segs.first
      end
      parent = segs[0..-2]
      parent.empty? ? :root : parent.first
    end

    # " URL [ENV] [OPTIONS]" - shows the positional-fill names for
    # declared non-boolean opts (required bare, optional bracketed), plus
    # a generic [OPTIONS] tail if any flags exist.
    def usage_signature(cmd)
      pos = cmd.options.reject(&:boolean?).map { |o|
        name = o.name.to_s.upcase
        o.required ? name : "[#{name}]"
      }
      out = pos.join(' ')
      out = "#{out} ".lstrip unless out.empty?
      out += '[OPTIONS]' unless cmd.options.empty?
      out.empty? ? '' : " #{out}"
    end

    def print_command_help(cmd, full = nil)
      full ||= cmd.name
      Shell.say "Usage: #{program_name} #{full}#{usage_signature(cmd)}", :cyan
      cmd.desc.each_line do |line|
        stripped = line.chomp
        Shell.say(stripped.empty? ? '' : "  #{stripped}")
      end unless cmd.desc.empty?
      Shell.say "  alias: #{cmd.alts.join(', ')}" unless cmd.alts.empty?
      Shell.say "  cron: #{cmd.cron}" if cmd.cron
      unless cmd.options.empty?
        Shell.say ''
        Shell.say 'Options:', :yellow
        cmd.options.each { |o| Shell.say "  #{o.usage}" }
      end
      unless cmd.examples.empty?
        Shell.say ''
        Shell.say 'Examples:', :yellow
        cmd.examples.each { |e| Shell.say "  #{program_name} #{e}" }
      end
    end
  end

  # Inside a command's `proc do |opts| ... end`, call sibling commands:
  #
  #   task :deploy do
  #     proc do |opts|
  #       hammer :build
  #       hammer 'db:migrate', pretend: true
  #     end
  #   end
  #
  # Dispatches from the root class so colon paths resolve against the
  # full tree even when called from inside a namespaced command.
  def hammer(name, *args, **opts)
    self.class.root.hammer(name, *args, **opts)
  end

  # ----- block DSL -----------------------------------------------------

  # Define and run a CLI inline. Inside the block use
  # `task :name do ... end`, `namespace`, and `load`.
  #
  # Without a block: load ./Hammerfile if it exists, otherwise
  # auto-discover *_hammer.rb under Dir.pwd, then dispatch ARGV.
  def self.run(argv = ARGV, &block)
    klass = Class.new(Hammer)
    if block
      Builder.new(klass).evaluate(&block)
    else
      hf = File.join(Dir.pwd, 'Hammerfile')
      if File.file?(hf)
        Builder.new(klass).evaluate(File.read(hf), hf)
      else
        klass.loader.load(Dir.pwd, [], auto: true)
      end
    end
    klass.start(argv)
  end

  # Entry point for recipe stubs in PATH. A recipe is a standalone
  # Hammerfile-style script bundled with the gem (or in
  # ~/.config/hammer/recipes/) that is exposed as its own bin via a
  # tiny Ruby wrapper containing:
  #
  #   require 'lux-hammer'
  #   Hammer.recipe(:srt, ARGV)
  #
  # The recipe runs as a self-contained CLI: program_name is the recipe
  # name, only its own tasks show in --help, no global hammer commands
  # appear. Runs in the caller's cwd (no chdir, no Hammerfile lookup).
  def self.recipe(name, argv = ARGV)
    path = Recipe.path(name)
    unless path
      Shell.print_error "unknown recipe: #{name}"
      Shell.say 'available recipes:', :yellow
      Recipe.all.keys.sort.each { |n| Shell.say "  #{n}" }
      Shell.say 'try `hammer h:recipes` to list with descriptions', :gray
      exit 1
    end

    klass = Class.new(Hammer)
    klass.instance_variable_set(:@program_name, name.to_s)
    Builder.new(klass).evaluate(File.read(path), path)
    klass.start(argv)
  end

  # Dump the gem's AGENTS.md to stdout - AI-optimized guide for
  # writing Hammerfiles. Bundled with the gem and resolved relative
  # to this file so it works from any install location.
  def self.print_ai_help
    path = File.expand_path('../AGENTS.md', __dir__)
    if File.file?(path)
      puts File.read(path)
    else
      Shell.print_error "AGENTS.md not found at #{path}"
      exit 1
    end
  end

  # Canonical starter Hammerfile. Written verbatim by `hammer --init`
  # and shown inline by `print_hammerfile_example` (the `Hammerfile
  # example:` block in `hammer --help`) - one source of truth for both.
  # Annotated as a mini tutorial of the common DSL surface in one task.
  # Single-quoted heredoc so file contents pass through unescaped.
  STARTER_HAMMERFILE ||= <<~'RUBY'
    desc 'My project tools'

    # `namespace :name do ... end` groups tasks under a colon prefix.
    # Address as `hammer demo:greet`.
    namespace :demo do
      # run before every task - global, or on a namespace
      before { say.gray "[demo] booting in #{Dir.pwd}" }

      task :greet do
        desc    'Demo task - shows the common DSL features in one place'
        example 'demo:greet world --from=alice --loud --times=3'
        alt     :hi                     # `hammer demo:hi` also dispatches here

        opt :from,  default: 'anon',              desc: 'who is greeting'
        opt :loud,  type: :boolean, alias: :l,    desc: 'shout the greeting'
        opt :times, type: :integer, default: 1,   desc: 'repeat N times'

        proc do |opts|
          who = opts[:args].first || 'world'
          msg = "hello #{who} from #{opts[:from]}"
          msg = msg.upcase if opts[:loud]
          opts[:times].times { say msg, :cyan }
        end
      end
    end
  RUBY

  # Default install dir used by install.sh and `hammer h:update`.
  SELF_UPDATE_DIR  ||= File.expand_path('~/.local/share/lux-hammer')
  SELF_UPDATE_REPO ||= 'https://github.com/dux/hammer.git'
  SELF_INSTALL_URL ||= 'https://raw.githubusercontent.com/dux/hammer/main/install.sh'

  # `hammer h:update`: pull main in the install-script checkout and
  # reinstall the gem. Assumes the install.sh layout - if the dir is
  # missing, point the user at the curl-pipe installer.
  def self.self_update
    dir = ENV['LUX_HAMMER_DIR'] || SELF_UPDATE_DIR
    unless File.directory?(File.join(dir, '.git'))
      Shell.print_error "no lux-hammer git checkout at #{dir}"
      Shell.say 'reinstall with:', :yellow
      Shell.say "  curl -fsSL #{SELF_INSTALL_URL} | bash"
      exit 1
    end

    Shell.say "* updating lux-hammer at #{dir}", :cyan
    Dir.chdir(dir) do
      run_or_exit('git', 'fetch', '--quiet', 'origin', 'main')
      run_or_exit('git', 'reset', '--quiet', '--hard', 'origin/main')
      version = File.read('.version').strip
      gem_file = "lux-hammer-#{version}.gem"
      run_or_exit('gem', 'build', 'lux-hammer.gemspec', out: File::NULL)
      run_or_exit('gem', 'install', '--quiet', gem_file)
      File.unlink(gem_file) if File.exist?(gem_file)
      Shell.say "* lux-hammer #{version} installed", :green
    end
  end

  def self.run_or_exit(*cmd, **opts)
    return if system(*cmd, **opts)
    Shell.print_error "command failed: #{cmd.join(' ')}"
    exit 1
  end

  # Entry point for the `hammer` binary. Walks up from CWD until it
  # finds a Hammerfile, evaluates it as the block DSL, then dispatches
  # ARGV against the resulting CLI.
  #
  # `--system` forces the no-Hammerfile branch even from inside a
  # project - the escape hatch for reaching `recipes`/`init` when a
  # user-defined task tree would otherwise own the root.
  def self.cli(argv = ARGV)
    argv = argv.dup
    force_system = !!argv.delete('--system')
    launch_gui   = !!argv.delete('--gui')

    # Shebang invocation: `hammer /path/to/script ...args` (kernel passes
    # the script path as argv[0] for `#!/usr/bin/env hammer` files).
    # Treat the script as a self-contained CLI: no Hammerfile lookup, no
    # chdir (commands run in the caller's cwd), no `hammer`-binary
    # built-ins/banners. Detection requires a `#!`+`hammer` first line so
    # task names that happen to be paths don't get hijacked.
    if (script = shebang_script(argv.first))
      argv.shift
      return run_shebang(script, argv)
    end

    path = force_system ? nil : find_hammerfile(Dir.pwd)

    # `hammer --gui` opens the native macOS runner pointed at this project
    # (the Hammerfile's dir, or cwd when none was found). The CLI just
    # launches the bundled app and returns.
    return launch_gui!(path ? File.dirname(path) : Dir.pwd) if launch_gui

    unless path
      # No Hammerfile (or --system) - all built-ins are reachable. Bare
      # `hammer`, `hammer h:recipes`, `hammer h:update`, `hammer h:agents`,
      # `hammer h:version`, `hammer h:init` all work.
      if force_system || dispatches_to_builtin?(argv) || looks_like_builtin?(argv)
        klass = Class.new(Hammer)
        klass.instance_variable_set(:@hammer_binary, true)
        # No project Hammerfile was found - only built-ins are loaded. The
        # bare-invocation help uses this to note that no Hammerfile exists.
        klass.instance_variable_set(:@no_hammerfile, true)
        klass.program_name
        require_relative 'hammer/builtins'
        Hammer::Builtins.register(klass)
        klass.start(argv)
        return
      end

      Shell.print_error "no Hammerfile found in #{Dir.pwd} or any parent directory"

      # Heuristic: *.rb files referencing `Hammer.` are likely inline CLIs
      # the user could promote into a Hammerfile.
      excludes = %w[.git node_modules tmp vendor coverage dist build]
                 .map { |d| "--exclude-dir=#{d}" }.join(' ')
      candidates = `grep -rl --include='*.rb' #{excludes} 'Hammer\\.' . 2>/dev/null`
                   .lines.map(&:strip).reject(&:empty?)
      unless candidates.empty?
        Shell.say "possible CLI implementation(s) - files referencing `Hammer.`:", :yellow
        candidates.first(10).each { |f| Shell.say "  #{f.sub(%r{\A\./}, '')}" }
        Shell.say ''
      end

      Shell.say "create one - example:"
      puts
      Shell.say STARTER_HAMMERFILE
      Shell.say ''
      bin = File.basename($PROGRAM_NAME)
      Shell.say "tip: run `#{bin} h:init` to drop the example above into ./Hammerfile", :gray
      Shell.say "tip: run `#{bin} h:agents` for AI-friendly Hammerfile authoring docs", :gray
      exit 1
    end

    klass = Class.new(Hammer)
    # Mark this class as the `hammer` binary's root so help output can
    # surface binary-only sections (`Recipes:` listing).
    klass.instance_variable_set(:@hammer_binary, true)
    # Resolve before chdir so paths like `bin/foo` stay relative to the
    # cwd the user actually invoked from. `program_name` memoizes.
    klass.program_name

    # chdir into the Hammerfile's directory for the entire run so commands
    # operate on the project root (Rake-style).
    Dir.chdir(File.dirname(path))
    Builder.new(klass).evaluate(File.read(path), path)
    # Auto-load `.env` / `.env.local` after eval so a top-level
    # `dotenv false` in the Hammerfile can suppress it. Trade-off: vars
    # are NOT visible during Hammerfile evaluation, only inside handlers.
    Hammer::Dotenv.load(Dir.pwd) if klass.dotenv_enabled?

    # Built-ins register AFTER Hammerfile eval so user-defined tasks win
    # (the `unless commands.key?(...)` guards skip a built-in when the
    # Hammerfile already owns the name - no redefinition warning). All
    # built-ins live under `h:`, so they can't collide with project root
    # tasks and the full set registers in every context.
    require_relative 'hammer/builtins'
    Hammer::Builtins.register(klass)

    klass.start(argv)
  end

  # Returns the script path if `arg` looks like a shebang script that
  # delegates to hammer (first line starts with `#!` and mentions
  # `hammer`). Returns nil otherwise. Used by `cli` to detect
  # `#!/usr/bin/env hammer` invocations where the kernel passes the
  # script path as argv[0].
  def self.shebang_script(arg)
    return nil unless arg
    return nil if arg.start_with?('-')
    return nil unless File.file?(arg) && File.readable?(arg)
    head = File.open(arg, &:gets).to_s
    return nil unless head.start_with?('#!') && head.include?('hammer')
    arg
  end

  # Evaluate a shebang script as a self-contained CLI. Mirrors `recipe`
  # semantics: no chdir, no `@hammer_binary` flag, no `Builtins.register`
  # built-ins (so the script's `--help` shows only what it defines).
  # `program_name` is the script's basename so help reads "myscript foo"
  # rather than "hammer foo" - works even when invoked via a symlink in
  # PATH, since argv[0] is the path the user typed.
  def self.run_shebang(path, argv)
    klass = Class.new(Hammer)
    klass.instance_variable_set(:@program_name, File.basename(path))
    Builder.new(klass).evaluate(File.read(path), path)
    klass.start(argv)
  end

  # True if argv goes through a built-in dispatch path (`:default` or
  # `:help`) - meaning bare `hammer`, leading-flag invocations like
  # `hammer -h`, or explicit help requests. These don't need a project
  # Hammerfile to run.
  def self.dispatches_to_builtin?(argv)
    return true if argv.empty?
    first = argv.first
    first == 'help' || first == '-h' || first == '--help' || first.start_with?('-')
  end

  # True if argv targets the reserved `h:` built-in namespace (`h`, `h:`,
  # `h:update`, ...). Used in the no-Hammerfile branch to wake up the
  # built-ins for invocations like `hammer h:recipes` that aren't a flag
  # or help request.
  def self.looks_like_builtin?(argv)
    first = argv.first
    return false unless first
    first == 'h' || first.start_with?('h:')
  end

  # Walk up the directory tree looking for a Hammerfile.
  def self.find_hammerfile(start)
    dir = File.expand_path(start)
    loop do
      candidate = File.join(dir, 'Hammerfile')
      return candidate if File.file?(candidate)
      parent = File.dirname(dir)
      return nil if parent == dir
      dir = parent
    end
  end

  # Spawn the vendored macOS GUI (gui/Hammer.app), pointed at the project
  # dir and this hammer binary. Launched directly (not via `open`) so it
  # inherits the caller's environment - the GUI shells back out to this
  # same `hammer` for `h:json` and task runs, and that needs the same PATH.
  def self.launch_gui!(project_dir)
    bin = File.expand_path('../gui/Hammer.app/Contents/MacOS/HammerGUI', __dir__)
    unless File.executable?(bin)
      Shell.print_error "GUI app not found at #{bin}"
      Shell.say 'build it: ./gui/HammerGUI/build_app.sh', :yellow
      exit 1
    end
    hammer_bin = (File.realpath($PROGRAM_NAME) rescue File.expand_path($PROGRAM_NAME))
    pid = Process.spawn(bin, '--project', File.expand_path(project_dir), '--hammer', hammer_bin)
    Process.detach(pid)
    Shell.say "launched Hammer GUI for #{project_dir} (pid #{pid})", :green
  end

end

class Hammer
  # Built-in tasks of the `hammer` binary. Everything but :default lives
  # under the reserved `h:` namespace (e.g. `hammer h:update`,
  # `hammer h:recipes`) so the built-ins never collide with a project's
  # own root tasks. Only the bare `hammer` invocation and the
  # `-h`/`--help`/`help` request are handled at root - bare fires
  # :default, which also carries the `--version` convenience flag.
  module Builtins
    module_function

    # Single registration entry point - identical in every context
    # (project Hammerfile or bare `hammer` binary). Namespacing under
    # `h:` removes the old collision worries, so there's no core vs
    # no-project split and no hidden-desc dance: the same tasks register
    # everywhere, always dispatchable, and surface in the listing only
    # under the extended `--help` view (the `@builtin_namespace` flag).
    def register(klass)
      register_default(klass) unless klass.commands.key?('default')

      existed = klass.namespaces.key?('h')
      klass.namespace(:h) {}          # ensure/reopen the reserved subclass
      h = klass.namespaces['h']
      # Flag the tree so the compact listing prunes it - the built-ins
      # only show under the extended `--help` view (always dispatchable).
      # Skip when the user already owns an `h:` namespace, so their own
      # tasks stay visible in the bare listing.
      h.instance_variable_set(:@builtin_namespace, true) unless existed
      register_help(h)    unless h.commands.key?('help')
      register_update(h)  unless h.commands.key?('update')
      register_agents(h)  unless h.commands.key?('agents')
      register_version(h) unless h.commands.key?('version')
      register_recipes(h) unless h.commands.key?('recipes')
      register_init(h)    unless h.commands.key?('init')
      register_json(h)    unless h.commands.key?('json')
      register_cron(h)    unless h.commands.key?('cron')
    end

    def register_help(klass)
      klass.class_eval do
        task :help do
          desc <<~TXT
            Show help. Optional TARGET = command name or namespace (`ns:`).

            Without TARGET prints the extended top-level help (commands,
            recipes, global flags, examples). With a command path prints
            per-command help; with a namespace prefix prints that
            namespace's command listing.
          TXT
          example 'h:help'
          example 'h:help build'
          example 'h:help db:'
          proc do |opts|
            self.class.root.print_help(opts[:args].first, extended: true)
          end
        end
      end
    end

    # `:default` fires on bare `hammer` and on leading-flag invocations
    # (other than -h/--help). Hidden from listings (no desc). All it
    # does now is print help - the old flag opts (--update, --ai, ...)
    # moved to dedicated tasks (:update, :agents, ...).
    def register_default(klass)
      klass.class_eval do
        task :default do
          opt :version, type: :boolean, alias: :v, desc: 'print lux-hammer version'
          # Inlined rather than dispatched to :version - going through
          # `hammer :version` would print the gray run banner. The
          # implementation is one line; not worth the indirection.
          proc do |opts|
            if opts[:version]
              puts Hammer::VERSION
            else
              self.class.root.print_help
            end
          end
        end
      end
    end

    def register_update(klass)
      klass.class_eval do
        task :update do
          desc 'Rebuild + reinstall lux-hammer from main'
          proc { Hammer.self_update }
        end
      end
    end

    def register_agents(klass)
      klass.class_eval do
        task :agents do
          desc 'Print AGENTS.md (Hammerfile authoring docs for AI assistants)'
          proc { Hammer.print_ai_help }
        end
      end
    end

    def register_version(klass)
      klass.class_eval do
        task :version do
          desc 'Print lux-hammer version'
          proc { puts Hammer::VERSION }
        end
      end
    end

    def register_init(klass)
      klass.class_eval do
        task :init do
          desc 'Write a starter Hammerfile in the current directory'
          proc { Hammer::Builtins.write_starter_hammerfile }
        end
      end
    end

    # The job server: runs every task that declares `cron '<expr>'` on
    # its schedule, in the foreground, with a localhost web UI for
    # status, logs and manual triggers. Per-job logs land in log/hammer/
    # (rotated at 1 MB, max 2 files), state in tmp/hammer/cron.state.json.
    def register_cron(klass)
      klass.class_eval do
        task :cron do
          desc <<~TXT
            Job server: run tasks that declare a `cron '<expr>'` schedule.

            Runs in the foreground (Ctrl-C to stop) with a web UI on
            localhost for job status, per-job logs and manual runs. Use
            --service to print a launchd plist / systemd unit and let the
            OS supervise it.
          TXT
          example 'h:cron'
          example 'h:cron --port=7777'
          example 'h:cron --pass=secret'
          example 'h:cron --list'
          example 'h:cron --service > ~/.config/systemd/user/hammer-cron.service'
          opt :port,    type: :integer, default: 4267, desc: 'web UI port (binds 127.0.0.1 only)'
          opt :pass,    type: :string,  desc: 'HTTP basic-auth password for the web UI (or CRON_HTTP_PASS env)'
          opt :list,    type: :boolean, desc: 'print scheduled jobs + next runs, then exit'
          opt :service, type: :boolean, desc: 'print a launchd plist (macOS) / systemd unit (linux)'
          proc do |opts|
            if self.class.root.instance_variable_get(:@no_hammerfile)
              error "no Hammerfile found - h:cron needs a project with scheduled tasks"
            end
            require_relative 'cron_server'
            server = Hammer::CronServer.new(self.class.root, port: opts[:port],
                                            pass: opts[:pass] || ENV['CRON_HTTP_PASS'])
            if opts[:service]
              server.print_service_unit
            elsif opts[:list]
              server.print_startup_summary
            else
              server.run!
            end
          end
        end
      end
    end

    def register_json(klass)
      klass.class_eval do
        task :json do
          desc <<~TXT
            Dump the CLI definition as JSON: tasks grouped exactly like
            the bare-`hammer` listing, each with desc, options, examples,
            aliases, needs. Consumed by the macOS GUI and any tooling
            that wants the full Hammerfile spec.
          TXT
          example 'h:json'
          example 'h:json --all       # include the reserved h: tasks'
          example 'h:json --compact   # minified, single line'
          opt :all,     type: :boolean, desc: 'include reserved built-in h: tasks'
          opt :compact, type: :boolean, desc: 'minified JSON (default: pretty)'
          proc do |opts|
            require 'json'
            spec = self.class.root.export_spec(include_builtins: opts[:all])
            puts opts[:compact] ? JSON.generate(spec) : JSON.pretty_generate(spec)
          end
        end
      end
    end

    # `:recipes` rolls all recipe-management actions into one task. Bare
    # invocation lists; opts pick the action and positional args carry
    # the recipe name (and optional target path for --install). Run via
    # `--run NAME [ARGS]` - use `--` to forward flags to the recipe
    # itself (e.g. `hammer h:recipes --run srt -- --help`).
    def register_recipes(klass)
      klass.class_eval do
        task :recipes do
          desc <<~TXT
            Manage recipes - the standalone Hammerfile-style scripts
            bundled with the gem (and under ~/.config/hammer/recipes).
            Bare invocation lists; flags pick the action.
          TXT
          opt :install, type: :boolean, desc: 'install recipe stub (picker if no NAME). With TARGET path: write + chmod.'
          opt :show,    type: :boolean, desc: 'cat recipe source'
          opt :path,    type: :boolean, desc: 'print recipe abs path'
          opt :edit,    type: :boolean, desc: 'open recipe in $EDITOR (copies gem -> user dir first)'
          opt :run,     type: :boolean, desc: 'run a recipe without installing its bin (forwards remaining args)'
          example 'h:recipes'
          example 'h:recipes --install srt ~/bin/srt    # write + chmod in one shot'
          example 'h:recipes --install srt > ~/bin/srt && chmod +x $_'
          example 'h:recipes --show srt'
          example 'h:recipes --run srt extract movie.mp4'
          example 'h:recipes --run srt -- --help        # -- forwards flags to the recipe'
          proc do |opts|
            args = opts[:args]
            if opts[:install]
              Hammer::Builtins::RecipesActions.install(args[0], args[1])
            elsif opts[:show]
              Hammer::Builtins::RecipesActions.show(Hammer::Builtins::RecipesActions.require_name!(args[0], 'show'))
            elsif opts[:path]
              Hammer::Builtins::RecipesActions.path(Hammer::Builtins::RecipesActions.require_name!(args[0], 'path'))
            elsif opts[:edit]
              Hammer::Builtins::RecipesActions.edit(Hammer::Builtins::RecipesActions.require_name!(args[0], 'edit'))
            elsif opts[:run]
              name = Hammer::Builtins::RecipesActions.require_name!(args[0], 'run')
              Hammer.recipe(name, args[1..])
            else
              Hammer::Builtins::RecipesActions.list
            end
          end
        end
      end
    end

    # Writes ./Hammerfile with the canonical starter template. Refuses
    # if one already exists - `init` must not clobber.
    def write_starter_hammerfile
      target = File.join(Dir.pwd, 'Hammerfile')
      if File.exist?(target)
        Shell.print_error "Hammerfile already exists at #{target}"
        exit 1
      end
      File.write(target, Hammer::STARTER_HAMMERFILE)
      Shell.say "created #{target}", :green
    end

    # Implementations of the `recipes` task's action flags, plus the
    # no-flag listing view. Separate module so the task definition above
    # stays small.
    module RecipesActions
      module_function

      def require_name!(name, action)
        return name if name
        Shell.print_error "missing recipe name (usage: h:recipes --#{action} NAME)"
        exit 1
      end

      # Group by source dir; each row shows desc and installed-or-not.
      def list
        groups = Hammer::Recipe.grouped
        if groups.empty?
          Shell.say 'no recipes found', :gray
          return
        end

        rows = Hammer::Recipe.all.map do |name, path|
          [name, Hammer::Recipe.desc(path), Hammer::Recipe.installed_path(name)]
        end
        width = rows.map { |n, _, _| n.length }.max

        groups.each_with_index do |(source, items), i|
          Shell.say '' if i > 0
          Shell.say "#{source}:", :yellow
          items.each_key do |name|
            _n, desc, installed = rows.find { |r| r.first == name }
            status = installed ? "(installed: #{installed})" : "[install: hammer h:recipes --install #{name}]"
            line = "  #{name.ljust(width)}  # #{desc}"
            Shell.say line
            Shell.say "  #{' ' * width}    #{status}", :gray
          end
        end
      end

      # With no NAME: arrow-key picker. With NAME only: print the stub
      # to stdout (user pipes it themselves). With NAME + TARGET: write
      # the stub to TARGET and chmod +x in one shot.
      def install(name, target = nil)
        if name.nil?
          names = Hammer::Recipe.all.keys.sort
          if names.empty?
            Shell.print_error 'no recipes available'
            exit 1
          end
          idx = Shell.choose('pick a recipe to install', names)
          exit 1 if idx.nil?
          name = names[idx]
        end

        unless Hammer::Recipe.path(name)
          Shell.print_error "unknown recipe: #{name}"
          exit 1
        end

        stub = Hammer::Recipe.stub(name)
        if target
          path = File.expand_path(target)
          File.write(path, stub)
          File.chmod(0o755, path)
          Shell.say "installed #{name} -> #{path}", :green
        else
          puts stub
        end
      end

      def show(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        puts File.read(path)
      end

      def path(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        puts path
      end

      # For a gem recipe, offer to copy to user dir first so edits
      # survive `hammer h:update`. Then exec $EDITOR on the file.
      def edit(name)
        path = Hammer::Recipe.path(name) or fail_unknown(name)
        editor = ENV['EDITOR'] || ENV['VISUAL']
        unless editor
          Shell.print_error '$EDITOR not set'
          exit 1
        end

        if path.start_with?(Hammer::Recipe::GEM_DIR)
          user_dir = ENV['HAMMER_RECIPES_DIR'] || File.expand_path('~/.config/hammer/recipes')
          target = File.join(user_dir, "#{name}.rb")
          unless File.exist?(target)
            if Shell.yes?("copy gem recipe to #{target} before editing? (recommended)")
              require 'fileutils'
              FileUtils.mkdir_p(user_dir)
              FileUtils.cp(path, target)
              Shell.say "copied to #{target}", :green
              path = target
            end
          else
            path = target
          end
        end

        system(editor, path)
      end

      def fail_unknown(name)
        Shell.print_error "unknown recipe: #{name}"
        exit 1
      end
    end
  end
end

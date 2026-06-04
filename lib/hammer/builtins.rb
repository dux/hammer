class Hammer
  # Built-in tasks of the `hammer` binary - all live at the root level
  # (no reserved namespace). Two registration entry points:
  #
  # * register_core - tasks always available (subject to user override
  #   via the `unless commands.key?(...)` guard): :default, :help,
  #   :update, :agents, :version. These coexist with Hammerfile tasks.
  #   Pass `hidden: true` (the Hammerfile branch does) to keep them
  #   dispatchable but drop them from the listing - see `hide_core`.
  #
  # * register_no_project - tasks meaningful only when no Hammerfile is
  #   loaded (or `--system` was passed): :recipes, :init. These would
  #   collide too easily with user tasks if always registered, so the
  #   Hammerfile branch skips them.
  module Builtins
    module_function

    def register_core(klass, hidden: false)
      preexisting = klass.commands.keys
      register_help(klass)    unless klass.commands.key?('help')
      register_default(klass) unless klass.commands.key?('default')
      register_update(klass)  unless klass.commands.key?('update')
      register_agents(klass)  unless klass.commands.key?('agents')
      register_version(klass) unless klass.commands.key?('version')
      hide_core(klass, preexisting) if hidden
    end

    # When a Hammerfile owns the task tree, the core built-ins stay
    # dispatchable but drop out of the listing so only project tasks
    # show. Empty desc = hidden-but-callable - same convention as
    # private helper tasks; :default already carries no desc. Only the
    # built-ins we just registered are hidden: a command the Hammerfile
    # defined itself (in `preexisting`) keeps its own desc.
    CORE_HIDEABLE ||= %w[help update agents version].freeze

    def hide_core(klass, preexisting)
      CORE_HIDEABLE.each do |name|
        next if preexisting.include?(name)
        cmd = klass.commands[name]
        cmd.instance_variable_set(:@desc, '') if cmd
      end
    end

    def register_no_project(klass)
      register_recipes(klass) unless klass.commands.key?('recipes')
      register_init(klass)    unless klass.commands.key?('init')
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
          example 'help'
          example 'help build'
          example 'help db:'
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

    # `:recipes` rolls all recipe-management actions into one task. Bare
    # invocation lists; opts pick the action and positional args carry
    # the recipe name (and optional target path for --install). Run via
    # `--run NAME [ARGS]` - use `--` to forward flags to the recipe
    # itself (e.g. `hammer recipes --run srt -- --help`).
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
          example 'recipes'
          example 'recipes --install srt ~/bin/srt    # write + chmod in one shot'
          example 'recipes --install srt > ~/bin/srt && chmod +x $_'
          example 'recipes --show srt'
          example 'recipes --run srt extract movie.mp4'
          example 'recipes --run srt -- --help        # -- forwards flags to the recipe'
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
        Shell.print_error "missing recipe name (usage: recipes --#{action} NAME)"
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
            status = installed ? "(installed: #{installed})" : "[install: hammer recipes --install #{name}]"
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
      # survive `hammer update`. Then exec $EDITOR on the file.
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

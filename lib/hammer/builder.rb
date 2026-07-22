class Hammer
  # Context object for the block DSL - what runs inside a `Hammerfile`,
  # a `Hammer.run do ... end` block, or any other top-level fragment.
  # All methods proxy to the target Hammer subclass.
  class Builder
    def initialize(klass)
      @klass = klass
    end

    # Top-level CLI description, shown under the Usage line in
    # `hammer --help`. Multi-line strings render with each line indented.
    def desc(text)
      @klass.app_desc(text)
    end

    # Open the underlying Hammer subclass to add private instance methods
    # callable from inside task procs. Lets recipe / Hammerfile authors
    # share helpers without a `Foo.method` prefix or a separate module:
    #
    #   helpers do
    #     def run(cmd) ; say cmd, :gray ; system cmd ; end
    #   end
    #
    #   task :ship do
    #     proc { run 'git push' }
    #   end
    #
    # Procs run via `instance.instance_exec(opts, &handler)` on a fresh
    # subclass instance, so anything `class_eval`'d here is in scope.
    def helpers(&block)
      @klass.class_eval(&block)
    end

    def task(name, &block)
      @klass.task(name, &block)
    end

    def namespace(name, &block)
      @klass.namespace(name, &block)
    end

    # Per-target / per-namespace pre-hook. Same semantics as
    # `Hammer.before` at the class level - see lux-hammer.rb.
    def before(&block)
      @klass.before(&block)
    end

    # Options available on every command (see Hammer.global_opt).
    def global_opt(name, **opts)
      @klass.global_opt(name, **opts)
    end

    # Opt out of auto `.env` loading in `Hammer.cli`. Default is on.
    def dotenv(flag = true)
      @klass.dotenv(flag)
    end

    # Same surface as `Hammer.load`. Resolved relative to the file that
    # called us, so `load auto: true` inside a Hammerfile picks up
    # *_hammer.rb under the Hammerfile's directory.
    def load(*paths, **kwargs)
      anchor = Loader.caller_anchor(caller_locations(1, 1).first)
      @klass.loader.load(anchor, paths, kwargs)
    end

    # instance_eval wrapper that also publishes the current Hammer target
    # via Thread.current[:hammer_target]. That lets `*_hammer.rb` files
    # pulled in through Ruby's own `require` (e.g. `Dir.require_all
    # 'lib/tasks'` inside a Hammerfile) call `task`/`namespace`/`before`
    # at top-level scope and have them register on the right target.
    def evaluate(source = nil, path = nil, &block)
      Hammer.with_target(@klass) do
        block ? instance_eval(&block) : instance_eval(source, path)
      end
    end
  end

  # Top-level Hammer DSL. Extended onto `main` (below) so any file
  # `require`d from within a Hammerfile - where `self == main` - can
  # still call `task`, `namespace`, and `before`. Delegates to whichever
  # Hammer subclass is currently being evaluated.
  module DSL
    %i[task namespace before dotenv global_opt].each do |m|
      define_method(m) do |*args, &block|
        target = Thread.current[:hammer_target]
        raise Hammer::Error, "`#{m}` called outside a Hammer context " \
                             '(Hammerfile / Hammer.run block / *_hammer.rb)' unless target
        target.send(m, *args, &block)
      end
    end

    # Top-level `desc 'text'` from inside a Hammerfile / fragment - sets
    # the CLI's overall description on the current target. Separate from
    # the class-level `desc` (which is per-task pending state).
    def desc(text)
      target = Thread.current[:hammer_target]
      raise Hammer::Error, '`desc` called outside a Hammer context ' \
                           '(Hammerfile / Hammer.run block / *_hammer.rb)' unless target
      target.app_desc(text)
    end

    # Same as Builder#helpers - top-level `helpers do ... end` in a
    # fragment or Hammerfile adds private instance methods to the
    # current target's class.
    def helpers(&block)
      target = Thread.current[:hammer_target]
      raise Hammer::Error, '`helpers` called outside a Hammer context ' \
                           '(Hammerfile / Hammer.run block / *_hammer.rb)' unless target
      target.class_eval(&block)
    end
  end
end

TOPLEVEL_BINDING.eval('self').extend(Hammer::DSL)

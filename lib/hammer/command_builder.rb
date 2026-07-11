class Hammer
  # Context object for `task :name do ... end` blocks. Exposes
  # desc/example/opt/alt; the block's return value (a `proc do |opts|`)
  # becomes the command handler.
  class CommandBuilder
    def initialize(cmd)
      @cmd = cmd
    end

    def desc(text)
      @cmd.instance_variable_set(:@desc, text.to_s.rstrip)
    end

    def example(text)
      @cmd.add_example(text)
    end

    def opt(name, **opts)
      @cmd.add_option(Option.new(name, **opts))
    end

    def alt(*names)
      names.each { |n| @cmd.add_alt(n) }
    end

    def needs(*names)
      names.each { |n| @cmd.add_need(n) }
    end

    # Schedule this task for the `hammer h:cron` job server. Accepts a
    # 5-field cron expression ('*/10 * * * *'), a simple interval ('10s',
    # '10m', '2h', '1d') or a shortcut (@hourly, @daily, @weekly,
    # @monthly). Validated immediately, so a typo fails at Hammerfile load.
    def cron(expr)
      @cmd.set_cron(expr)
    end
  end
end

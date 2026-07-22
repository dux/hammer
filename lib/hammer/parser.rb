class Hammer
  # Parses ARGV into positional args and an options hash, given a set
  # of `Option` definitions.
  class Parser
    Error ||= Class.new(StandardError)

    def initialize(options)
      @options   = options
      @by_switch = {}
      options.each do |opt|
        register_switch(opt.switch, opt)
        opt.aliases.each { |a| register_switch(a, opt) }
      end
    end

    def parse(argv)
      positional = []
      values     = {}
      i = 0
      argv = argv.dup

      while i < argv.length
        token = argv[i]

        if token == '--'
          positional.concat(argv[(i + 1)..])
          break
        end

        if token.start_with?('--') && token.include?('=')
          key, val = token.split('=', 2)
          opt = lookup!(key)
          values[opt.name] = opt.cast(val)
          i += 1
          next
        end

        if @by_switch.key?(token)
          opt = @by_switch[token]
          if opt.boolean?
            # Presence alone is enough — the flag is true regardless of name.
            values[opt.name] = true
            i += 1
          else
            val = argv[i + 1]
            raise Error, "missing value for #{token}" if val.nil?
            values[opt.name] = opt.cast(val)
            i += 2
          end
          next
        end

        # Glued short flag with value: `-pVALUE` (non-boolean short opts only).
        if token.start_with?('-') && !token.start_with?('--') && token.length > 2
          if (opt = @by_switch[token[0, 2]]) && !opt.boolean?
            values[opt.name] = opt.cast(token[2..])
            i += 1
            next
          end
        end

        # Dash-led and not a negative number -> a genuinely unknown flag.
        # Bare `-` and negative numbers (`-5`) fall through to positionals.
        if token.start_with?('-') && token.length > 1 && token !~ /\A-\d/
          raise Error, "unknown option: #{token}"
        end

        positional << token
        i += 1
      end

      # Fill un-set non-boolean opts from positional args in declaration
      # order. Booleans always need an explicit flag. type: :json is flag/
      # stdin only (skip_positional_fill?). Scalars take one positional
      # each; an :array opt slurps whatever's left, so it's filled last
      # and never starves a later-declared scalar opt.
      array_opt = nil
      @options.each do |opt|
        next if opt.boolean? || opt.skip_positional_fill? || values.key?(opt.name)
        if opt.type == :array
          array_opt = opt
          next
        end
        break if positional.empty?
        values[opt.name] = opt.cast(positional.shift)
      end
      if array_opt && !positional.empty?
        values[array_opt.name] = array_opt.cast(positional.shift(positional.size))
      end

      @options.each do |opt|
        values[opt.name] = opt.default if !values.key?(opt.name) && !opt.default.nil?
        raise Error, "missing required --#{opt.name}" if opt.required && !values.key?(opt.name)
      end

      [positional, values]
    end

    private

    # Map a flag string to its option, refusing silent shadowing when two
    # options would claim the same switch/alias.
    def register_switch(flag, opt)
      if (prev = @by_switch[flag]) && prev != opt
        raise Error, "flag #{flag} claimed by both :#{prev.name} and :#{opt.name}"
      end
      @by_switch[flag] = opt
    end

    def lookup!(key)
      @by_switch[key] or raise Error, "unknown option: #{key}"
    end
  end
end

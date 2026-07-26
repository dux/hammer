class Hammer
  # Single option/flag definition.
  class Option
    attr_reader :name, :type, :default, :desc, :aliases, :required, :placeholder

    ALLOWED_KEYS    ||= %i[type default desc alias req placeholder positional].freeze
    RESERVED_FLAGS  ||= %w[-h --help].freeze

    def initialize(name, **opts)
      bad = opts.keys - ALLOWED_KEYS
      unless bad.empty?
        raise Hammer::Error,
              "unknown opt parameter(s) for :#{name}: #{bad.join(', ')}. " \
              "allowed: #{ALLOWED_KEYS.join(', ')}"
      end
      @name        = name.to_sym
      @type        = opts[:type] || :string
      @default     = opts[:default]
      @desc        = opts[:desc]
      @aliases     = Array(opts[:alias]).map { |a| Option.normalize_alias(a) }
      @required    = opts[:req] ? true : false
      # Custom usage placeholder, e.g. `placeholder: 't/f'` -> `--log t/f`.
      # Falls back to uppercased name (`--log LOG`) when nil.
      @placeholder = opts[:placeholder]
      # `positional: false` means "flag form only" - the option never claims a
      # bare positional. For commands that forward their positionals somewhere
      # else (`llm wrap --lines 3 -- claude`), the default fill would otherwise
      # swallow the first one.
      @positional  = opts.key?(:positional) ? !!opts[:positional] : true

      # Reserve -h / --help so every command supports them uniformly.
      if RESERVED_FLAGS.include?(switch)
        raise Hammer::Error, "opt :#{name} produces reserved flag #{switch.inspect} (used for help)"
      end
      clash = @aliases.find { |a| RESERVED_FLAGS.include?(a) }
      raise Hammer::Error, "alias #{clash.inspect} is reserved for help" if clash
    end

    # `:p` -> `-p`, `:dry_run` -> `--dry-run`. Strings starting with
    # `-` pass through untouched.
    def self.normalize_alias(value)
      s = value.to_s
      return s if s.start_with?('-')
      s.length == 1 ? "-#{s}" : "--#{s.tr('_', '-')}"
    end

    def boolean?
      type == :boolean
    end

    def switch
      "--#{name.to_s.tr('_', '-')}"
    end

    def cast(value)
      case type
      when :boolean then !!value && value != 'false' && value != '0'
      when :integer then Integer(value)
      when :float   then Float(value)
      when :array   then value.is_a?(Array) ? value : value.to_s.split(',')
      when :json
        # Hash/Array pass through. Strings may be inline JSON, @file, or "-"
        # (stdin resolved later by Hammer::Input.prepare_json!). "@" and
        # inline JSON are parsed here so opts[:x] is already a Hash in
        # the handler when the flag is used.
        return value if value.is_a?(Hash) || value.is_a?(Array)
        s = value.to_s
        return s if s == '-' || s.empty?
        Hammer::Input.resolve_json_value(s, {}, source: switch)
      else value.to_s
      end
    rescue ArgumentError, TypeError
      raise Hammer::Parser::Error, "invalid #{type} value for --#{name}: #{value.inspect}"
    end

    # JSON bodies are flags / stdin / @file — never bare positionals. Anything
    # declared `positional: false` opts out the same way.
    def skip_positional_fill?
      type == :json || !@positional
    end

    def usage
      flag = switch
      flag += " #{placeholder || name.to_s.upcase}" unless boolean?
      line = aliases.empty? ? flag : "#{aliases.join(', ')}, #{flag}"
      suffix = annotation
      line = "#{line.ljust(28)} #{desc}" if desc
      suffix.empty? ? line : "#{line} #{suffix}"
    end

    # "(default: dev)" or "(required)"
    def annotation
      return '(required)' if required
      return '' if default.nil?
      "(default: #{default.inspect})"
    end

    # Structured form for JSON export (`h:json`). The GUI maps `type`
    # to a form widget; `default`/`required`/`desc` decorate it. Mirrors
    # the data behind `usage`.
    def to_h
      {
        name:        name.to_s,
        type:        type.to_s,
        default:     default,
        required:    required,
        desc:        desc,
        placeholder: placeholder,
        switch:      switch,
        aliases:     aliases,
        usage:       usage.strip
      }
    end
  end
end

# frozen_string_literal: true

require 'json'

class Hammer
  # Stdin + JSON helpers for opts. Hammer exposes piped stdin as
  # `opts[:stdin]`, read lazily on first access; recipes opt into JSON body
  # handling via `Hammer::Input.prepare_json!` (typically from a `before`
  # hook) and/or `opt :json, type: :json` / `global_opt :json, type: :json`.
  module Input
    module_function

    # Read piped stdin once. Returns nil when stdin is a TTY or empty.
    # Does not consume an interactive TTY, and does not block on a socket
    # that has nothing pending: agent harnesses (Claude Code's Bash tool)
    # hand every command a unix socket as stdin that never reaches EOF, so
    # a plain read would hang there for good. A shell pipe or a redirected
    # file is a FIFO or a regular file and is still read in full.
    def read_stdin
      return nil if $stdin.closed?
      return nil if $stdin.tty?
      return nil if idle_socket?($stdin)

      data = $stdin.read
      return nil if data.nil?

      data = data.dup.force_encoding(Encoding::UTF_8) if data.respond_to?(:force_encoding)
      data.empty? ? nil : data
    rescue StandardError
      nil
    end

    def idle_socket?(io)
      return false unless io.respond_to?(:stat) && io.stat.socket?

      IO.select([io], nil, nil, 0).nil?
    rescue StandardError
      false
    end

    # Reads stdin into the hash on the first `opts[:stdin]` lookup and keeps
    # the result, so a command that never asks for stdin never waits on it.
    LAZY_STDIN = lambda do |hash, key|
      key == :stdin ? (hash[:stdin] = Input.read_stdin) : nil
    end

    # Idempotent: leaves an explicit opts[:stdin] alone, otherwise installs
    # the lazy reader. Nothing is read until a recipe looks at opts[:stdin].
    def attach_stdin!(opts)
      return if opts.key?(:stdin) || opts.default_proc.equal?(LAZY_STDIN)

      opts.default_proc = LAZY_STDIN
    end

    # Parse a JSON source string into a Hash/Array with symbol keys.
    # source is only used in error messages ('stdin', '--json', path, ...).
    def parse_json(raw, source: 'json')
      data = JSON.parse(raw)
      symbolize(data)
    rescue JSON::ParserError => e
      raise Hammer::Parser::Error, "invalid JSON (#{source}): #{e.message}"
    end

    # Resolve a value that may be:
    #   - Hash / Array  -> returned as-is (symbolized if Hash has string keys)
    #   - "-"           -> use opts[:stdin]
    #   - "@path"       -> File.read(path)
    #   - JSON string   -> parse
    def resolve_json_value(value, opts = {}, source: 'json')
      return symbolize(value) if value.is_a?(Hash) || value.is_a?(Array)

      s = value.to_s
      if s == '-'
        attach_stdin!(opts)
        raw = opts[:stdin]
        raise Hammer::Parser::Error, "no JSON on stdin for #{source}" if raw.nil? || raw.empty?

        return parse_json(raw, source: 'stdin')
      end

      if s.start_with?('@')
        path = s[1..]
        raise Hammer::Parser::Error, "JSON file not found: #{path}" unless File.file?(path)

        return parse_json(File.read(path), source: path)
      end

      parse_json(s, source: source)
    end

    # Prepare opts[key] as a Hash/Array when possible.
    #
    #   1. If opts[key] is already Hash/Array -> symbolize, done
    #   2. If opts[key] is a String ("...", @file, -) -> parse
    #   3. If opts[key] is nil/absent and opts[:stdin] looks like JSON
    #      object/array -> fill from stdin
    #   4. Boolean true/false left alone (legacy `opt :json, type: :boolean`)
    #
    # Returns the resolved value (or nil). Mutates opts.
    def prepare_json!(opts, key: :json)
      attach_stdin!(opts)
      key = key.to_sym
      val = opts[key]

      if val.is_a?(Hash) || val.is_a?(Array)
        opts[key] = symbolize(val)
        return opts[key]
      end

      if val.is_a?(String) && !val.empty?
        opts[key] = resolve_json_value(val, opts, source: "--#{key.to_s.tr('_', '-')}")
        return opts[key]
      end

      # Skip booleans (output-mode flags) and other non-nil junk.
      return val unless val.nil?

      raw = opts[:stdin]
      return nil if raw.nil? || raw.empty?

      stripped = raw.lstrip
      return nil unless stripped.start_with?('{', '[')

      opts[key] = parse_json(raw, source: 'stdin')
      opts[key]
    end

    def symbolize(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          h[k.respond_to?(:to_sym) ? k.to_sym : k] = symbolize(v)
        end
      when Array
        obj.map { |v| symbolize(v) }
      else
        obj
      end
    end
  end
end

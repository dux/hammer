# frozen_string_literal: true

require 'json'

class Hammer
  # Stdin + JSON helpers for opts. Hammer always attaches piped stdin as
  # `opts[:stdin]`; recipes opt into JSON body handling via
  # `Hammer::Input.prepare_json!` (typically from a `before` hook) and/or
  # `opt :json, type: :json` / `global_opt :json, type: :json`.
  module Input
    module_function

    # Read piped stdin once. Returns nil when stdin is a TTY or empty.
    # Does not consume an interactive TTY.
    def read_stdin
      return nil if $stdin.closed?
      return nil if $stdin.tty?

      data = $stdin.read
      return nil if data.nil?

      data = data.dup.force_encoding(Encoding::UTF_8) if data.respond_to?(:force_encoding)
      data.empty? ? nil : data
    rescue StandardError
      nil
    end

    # Idempotent: sets opts[:stdin] if not already present.
    def attach_stdin!(opts)
      return opts[:stdin] if opts.key?(:stdin)

      opts[:stdin] = read_stdin
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

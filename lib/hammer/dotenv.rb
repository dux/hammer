class Hammer
  # Tiny built-in .env loader. Kept dependency-free on purpose - the
  # gemspec advertises zero runtime deps.
  #
  # `Hammer.cli` calls `Dotenv.load(Dir.pwd)` after evaluating the
  # Hammerfile (unless the Hammerfile said `dotenv false`), so vars
  # from `.env` are available to every command handler.
  #
  # Semantics:
  # * `.env` is loaded, then `.env.local` (latter overrides former).
  # * Missing files are silently skipped - auto-load must not raise.
  # * Existing `ENV[k]` always wins (`ENV[k] ||= v`); shell-set values
  #   are never clobbered.
  # * Supported lines: `KEY=value`, `KEY="value"`, `KEY='value'`, optional
  #   leading `export `, `#` comments, blank lines.
  # * NOT supported: `${VAR}` interpolation, multiline values, inline
  #   comments after a value. Reach for the `dotenv` gem from a `before`
  #   hook if you need those.
  module Dotenv
    FILES ||= %w[.env .env.local].freeze

    def self.load(dir)
      FILES.each do |name|
        path = File.join(dir, name)
        next unless File.file?(path)
        parse(File.read(path)).each { |k, v| ENV[k] ||= v }
      end
    end

    def self.parse(text)
      out = {}
      text.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        line = line.sub(/\Aexport\s+/, '')
        key, sep, val = line.partition('=')
        next if sep.empty?
        key = key.strip
        next if key.empty?
        val = val.strip
        if val.length >= 2 &&
           ((val.start_with?('"') && val.end_with?('"')) ||
            (val.start_with?("'") && val.end_with?("'")))
          val = val[1..-2]
        end
        out[key] = val
      end
      out
    end
  end
end

class Hammer
  # Discovers and evaluates Hammerfile fragments (`*_hammer.rb`) against
  # a target `Hammer` subclass. One Loader per target class - the
  # target memoises it via `target.loader`. Holds the per-target dedup
  # cache so re-entrant `load` is safe.
  class Loader
    SKIP_DIRS ||= %w[.git .bundle node_modules tmp vendor dist build coverage].freeze

    attr_reader :loaded

    def initialize(target)
      @target = target
      @loaded = {}
    end

    # Resolve `caller_locations(...).first` to a directory.
    def self.caller_anchor(loc)
      path = loc&.absolute_path || loc&.path
      path ? File.dirname(path) : Dir.pwd
    end

    def load(anchor, paths, kwargs)
      bad = kwargs.keys - %i[auto]
      raise Hammer::Error, "load: unknown option(s): #{bad.join(', ')}" unless bad.empty?
      return if kwargs.key?(:auto) && !kwargs[:auto]

      files =
        if paths.empty?
          discover(anchor)
        else
          paths.flat_map { |p| resolve_pattern(anchor, p) }.uniq.sort
        end

      files.each { |f| load_one(f) }
    end

    private

    def resolve_pattern(anchor, pattern)
      abs = File.expand_path(pattern, anchor)
      # A real file/dir wins over glob interpretation, so a literal path
      # whose name contains [ ] { } * ? still resolves. Directory: discover
      # *_hammer.rb under it (empty result is OK - an app may have none).
      return [abs] if File.file?(abs)
      return discover(abs) if File.directory?(abs)
      if abs.match?(/[\*\?\[\{]/)
        matches = Dir.glob(abs).sort
        raise Hammer::Error, "load: no files matched #{pattern.inspect}" if matches.empty?
        return matches
      end
      raise Hammer::Error, "load: no files matched #{pattern.inspect}"
    end

    def discover(dir)
      return [] unless File.directory?(dir)
      out = []
      walk(dir, out, {})
      out.sort
    end

    # `seen` tracks visited real paths so a cyclic directory symlink
    # doesn't recurse forever.
    def walk(dir, out, seen)
      real = File.realpath(dir) rescue dir
      return if seen[real]
      seen[real] = true
      Dir.each_child(dir) do |entry|
        full = File.join(dir, entry)
        if File.directory?(full)
          next if SKIP_DIRS.include?(entry) || entry.start_with?('.')
          walk(full, out, seen)
        elsif entry.end_with?('_hammer.rb')
          out << full
        end
      end
    end

    def load_one(abs_path)
      return if @loaded[abs_path]
      @loaded[abs_path] = true
      Builder.new(@target).evaluate(File.read(abs_path), abs_path)
    rescue Hammer::Error
      raise
    rescue StandardError => e
      raise Hammer::Error, "failed loading #{abs_path}: #{e.message}"
    end
  end
end

class Hammer
  # The running version, read from the .version file next to the gem. vstamp
  # writes it as YAML (`version: X.Y.Z`, see github.com/dux/vstamp); a plain
  # `X.Y.Z` file is read too, so recipes work in repos not migrated yet.
  module Version
    module_function

    ROOT ||= File.expand_path('../..', __dir__)

    def string
      read(File.join(ROOT, '.version')) || 'dev'
    end

    # Version in a .version file, nil when the file is missing or has none.
    def read(path)
      return unless File.exist?(path)

      text = File.read(path)
      text[/^version:[ \t]*([^\s#]+)/, 1] || text[/\A\s*(v?\d+(?:\.\d+)*)\s*\z/, 1]
    end
  end
end

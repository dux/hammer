class Hammer
  # The running version, derived the way dboss derives its own: the number
  # of commits reachable from main (or master, or HEAD) rendered as a dotted
  # triple, so v82 -> 0.8.2 and v1123 -> 11.2.3. A released gem has no .git
  # and falls back to the .version file baked in at build time, which is also
  # what `hammer gem --inc` writes.
  module Version
    module_function

    ROOT ||= File.expand_path('../..', __dir__)

    # Dotted, no leading v, so it stays a valid Gem::Version (v1.2.3 -> 1.2.3).
    def string
      format(raw)
    end

    # v<commit count> in a git checkout, else the packaged .version string.
    def raw
      count = git_count
      count ? "v#{count}" : file_version
    end

    # v123 -> 1.2.3, v1123 -> 11.2.3, v5 -> 0.0.5. Anything that is not
    # v<digits> (dev, an already-dotted version) is returned unchanged.
    def format(version)
      text  = version.to_s
      count = text.start_with?('v') ? text[1..] : nil
      return text unless count && !count.empty? && count.match?(/\A\d+\z/)

      count = count.rjust(3, '0')
      "#{count[0...-2]}.#{count[-2]}.#{count[-1]}"
    end

    def git_count
      return nil unless File.exist?(File.join(ROOT, '.git'))

      %w[main master HEAD].each do |ref|
        out = IO.popen(['git', '-C', ROOT, 'rev-list', '--count', ref],
                       err: File::NULL, &:read).to_s.strip
        return out.to_i if out.match?(/\A\d+\z/)
      end
      nil
    rescue SystemCallError
      nil
    end

    def file_version
      path = File.join(ROOT, '.version')
      File.exist?(path) ? File.read(path).strip : 'dev'
    end
  end
end

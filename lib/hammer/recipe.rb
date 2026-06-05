class Hammer
  # Discovery + helpers for "recipes" - standalone Hammerfile-style
  # scripts shipped under `<gem>/recipes/` (and optionally the user's
  # `~/.config/hammer/recipes/`) that are exposed as their own bin
  # scripts in PATH via a tiny Ruby wrapper.
  module Recipe
    module_function

    GEM_DIR ||= File.expand_path('../../recipes', __dir__)

    # Recipe lookup directories, in priority order. User dir is only
    # included when it exists. Honors HAMMER_RECIPES_DIR for overrides
    # (mostly for tests).
    def dirs
      out = [GEM_DIR]
      user = ENV['HAMMER_RECIPES_DIR'] || File.expand_path('~/.config/hammer/recipes')
      out.unshift(user) if File.directory?(user)
      out
    end

    # { "name" => "/abs/path/name.rb" }. User-dir entries win over gem
    # entries because they come first in `dirs`.
    def all
      out = {}
      dirs.each do |dir|
        next unless File.directory?(dir)
        Dir.glob(File.join(dir, '*.rb')).sort.each do |path|
          name = File.basename(path, '.rb')
          out[name] ||= path
        end
      end
      out
    end

    # Path to the recipe file for `name`, or nil if unknown.
    def path(name)
      all[name.to_s]
    end

    # First `# desc: ...` line at the top of the file, or empty string.
    # Cheap - reads only the first ~20 lines, no eval.
    def desc(path)
      return '' unless path && File.file?(path)
      File.foreach(path).first(20).each do |line|
        if (m = line.match(/\A#\s*desc:\s*(.+)$/i))
          return m[1].strip
        end
      end
      ''
    end

    # Ruby wrapper text printed by `hammer h:recipes --install`. User
    # redirects it to a file in PATH and chmods +x. The leading comment
    # documents the canonical install command. Name is passed as a
    # string literal so hyphenated names (`git-helper`) work too.
    def stub(name)
      <<~RUBY
        #!/usr/bin/env ruby
        # install: hammer h:recipes --install #{name} > ~/bin/#{name} && chmod +x $_
        require 'lux-hammer'
        Hammer.recipe('#{name}', ARGV)
      RUBY
    end

    # If a stub for `name` is on PATH, return its absolute path. Detects
    # by reading the file and looking for the literal `Hammer.recipe('<name>'`
    # token - cheap and near-zero false positive.
    def installed_path(name)
      token = "Hammer.recipe('#{name}'"
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, name.to_s)
        next unless File.file?(candidate) && File.executable?(candidate)
        return candidate if File.read(candidate, 512).include?(token)
      rescue StandardError
        next
      end
      nil
    end

    # Group recipes by their source directory for the listing view.
    # Returns [[source_label, { name => path }], ...].
    def grouped
      user_dir = ENV['HAMMER_RECIPES_DIR'] || File.expand_path('~/.config/hammer/recipes')
      groups = { 'gem' => {}, 'user' => {} }
      all.each do |name, path|
        bucket = path.start_with?(user_dir) ? 'user' : 'gem'
        groups[bucket][name] = path
      end
      groups.reject { |_, v| v.empty? }.to_a
    end
  end
end

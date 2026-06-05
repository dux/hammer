require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class CliTest < Minitest::Test
  include CaptureIO

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  def test_finds_hammerfile_in_cwd
    with_hammerfile(<<~'RUBY') do |dir|
      task :greet do
        proc { |opts| say "hi #{opts[:args].first || 'world'}" }
      end
    RUBY
      out, = capture { Hammer.cli(%w[greet dino]) }
      assert_includes out, 'hi dino'
    end
  end

  def test_walks_up_for_hammerfile
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'Hammerfile'), <<~'RUBY')
        task :hi do
          proc { |_| say 'found' }
        end
      RUBY
      nested = File.join(root, 'a', 'b', 'c')
      FileUtils.mkdir_p(nested)
      Dir.chdir(nested) do
        out, = capture { Hammer.cli(['hi']) }
        assert_includes out, 'found'
      end
    end
  end

  def test_missing_hammerfile_with_empty_argv_shows_help
    # Bare `hammer` routes through the `:default` built-in task, which
    # falls through to `print_help` (brief project listing). No
    # Hammerfile is required - help works from anywhere.
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, _, status = capture_exit { Hammer.cli([]) }
        assert_nil status
        assert_includes out, 'Usage:'
      end
    end
  end

  def test_missing_hammerfile_with_help_shows_builtins
    # An explicit help request (`--help` / `-h` / `help`) with no
    # Hammerfile is treated as "what can hammer do?" - we surface the
    # built-in tasks and the Recipes: section so users can discover
    # tool-meta commands without having to bootstrap a project first.
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['--help']) }
        assert_includes out, 'agents'
        assert_includes out, 'recipes'
        assert_includes out, 'Recipes:'
      end
    end
  end

  def test_missing_hammerfile_with_user_command_exits_1
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        _, err, status = capture_exit { Hammer.cli(['build']) }
        assert_equal 1, status
        assert_includes err, 'no Hammerfile found'
      end
    end
  end

  def test_agents_task_dumps_agents_md
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['h:agents']) }
        assert_includes out, 'AGENTS.md - lux-hammer'
        assert_includes out, 'DSL surface'
      end
    end
  end

  def test_agents_task_works_with_hammerfile_present
    with_hammerfile(<<~'RUBY') do |_|
      task :hi do
        proc { |_| say 'HANDLER_FIRED_UNIQUE_MARKER' }
      end
    RUBY
      out, = capture { Hammer.cli(['h:agents']) }
      assert_includes out, 'AGENTS.md - lux-hammer'
      refute_includes out, 'HANDLER_FIRED_UNIQUE_MARKER'
    end
  end

  # ----- :default + :help built-ins ----------------------------------

  def test_version_task_prints_version
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['h:version']) }
      assert_includes out, Hammer::VERSION
    end
  end

  def test_version_task_works_without_hammerfile
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['h:version']) }
        assert_includes out, Hammer::VERSION
      end
    end
  end

  def test_init_writes_starter_hammerfile
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['h:init']) }
        assert_includes out, 'created'
        target = File.join(dir, 'Hammerfile')
        assert File.exist?(target)
        body = File.read(target)
        # File written must match the canonical constant verbatim.
        assert_equal Hammer::STARTER_HAMMERFILE, body
        assert_includes body, "task :greet"
        assert_includes body, 'namespace :demo'
      end
    end
  end

  def test_help_uses_same_template_as_init
    # `--help`'s Hammerfile example and `init`'s output must come from
    # the same source so the two never drift.
    with_hammerfile("task :x do; desc 'X'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--help']) }
      first_line = Hammer::STARTER_HAMMERFILE.lines.first.chomp
      assert_includes out, first_line
    end
  end

  def test_init_refuses_when_hammerfile_exists
    # `h:init` refuses to clobber an existing Hammerfile. Reach it via
    # --system so the lookup doesn't chdir into the project first.
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['--system', 'h:init']) }
      assert_equal 1, status
      assert_includes err, 'Hammerfile already exists'
    end
  end

  def test_user_can_override_default_task
    with_hammerfile(<<~'RUBY') do |_|
      task :default do
        opt :ping, type: :boolean
        proc do |opts|
          if opts[:ping]
            say 'pong'
          else
            say 'fell through'
          end
        end
      end
    RUBY
      out1, = capture { Hammer.cli(['--ping']) }
      assert_includes out1, 'pong'

      out2, = capture { Hammer.cli([]) }
      assert_includes out2, 'fell through'

      # Built-in --version is gone entirely (`hammer version` is the new
      # path) so this just verifies unknown flags surface from user :default.
      _, err, _ = capture_exit { Hammer.cli(['--frob']) }
      assert_includes err, 'unknown option'
    end
  end

  def test_user_can_override_help_task
    with_hammerfile(<<~'RUBY') do |_|
      task :help do
        desc 'my custom help'
        proc { |_| say 'CUSTOM_HELP_FIRED' }
      end
    RUBY
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'CUSTOM_HELP_FIRED'
    end
  end

  def test_help_task_target_passes_through
    with_hammerfile(<<~'RUBY') do |_|
      task :build do
        desc 'build it'
        proc { |_| say 'built' }
      end
    RUBY
      out, = capture { Hammer.cli(['help', 'build']) }
      assert_includes out, 'Usage:'
      assert_includes out, 'build'
      refute_includes out, 'built'  # handler did NOT run
    end
  end

  def test_namespaces_in_hammerfile
    with_hammerfile(<<~'RUBY') do |_|
      task :build do
        proc { |_| say 'built' }
      end
      namespace :db do
        task :migrate do
          proc { |_| say 'migrated' }
        end
      end
    RUBY
      out1, = capture { Hammer.cli(['build']) }
      out2, = capture { Hammer.cli(['db:migrate']) }
      assert_includes out1, 'built'
      assert_includes out2, 'migrated'
    end
  end
end

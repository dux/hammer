require_relative 'test_helper'
require 'hammer/builtins'

class BuiltinsTest < Minitest::Test
  include CaptureIO

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  def with_no_hammerfile
    Dir.mktmpdir { |dir| Dir.chdir(dir) { yield dir } }
  end

  # ----- dispatch trigger detection ---------------------------------

  def test_dispatches_to_builtin_for_bare_and_flag_and_help
    assert Hammer.dispatches_to_builtin?([])
    assert Hammer.dispatches_to_builtin?(['-h'])
    assert Hammer.dispatches_to_builtin?(['--help'])
    assert Hammer.dispatches_to_builtin?(['help'])
    assert Hammer.dispatches_to_builtin?(['--unknown-flag'])
    refute Hammer.dispatches_to_builtin?(['build'])
    refute Hammer.dispatches_to_builtin?(['db:migrate'])
  end

  def test_looks_like_builtin_for_builtin_task_names
    assert Hammer.looks_like_builtin?(['recipes'])
    assert Hammer.looks_like_builtin?(['update'])
    assert Hammer.looks_like_builtin?(['agents'])
    assert Hammer.looks_like_builtin?(['version'])
    assert Hammer.looks_like_builtin?(['init'])
    refute Hammer.looks_like_builtin?(['build'])
    refute Hammer.looks_like_builtin?([])
  end

  # ----- register_core ----------------------------------------------

  def test_register_core_adds_all_core_tasks
    klass = Class.new(Hammer)
    Hammer::Builtins.register_core(klass)
    %w[default help update agents version].each do |name|
      assert klass.commands.key?(name), "missing :#{name} after register_core"
    end
  end

  def test_register_core_skips_when_user_defined
    klass = Class.new(Hammer) do
      task :default do
        proc { |_| say 'mine' }
      end
      task :help do
        desc 'my help'
        proc { |_| say 'my help' }
      end
      task :update do
        desc 'my update'
        proc { |_| say 'my update' }
      end
    end
    Hammer::Builtins.register_core(klass)
    assert_equal 'my help', klass.commands['help'].desc
    assert_equal 'my update', klass.commands['update'].desc
  end

  def test_register_no_project_adds_recipes_and_init
    klass = Class.new(Hammer)
    Hammer::Builtins.register_no_project(klass)
    assert klass.commands.key?('recipes')
    assert klass.commands.key?('init')
  end

  # ----- self: namespace is no longer reserved ----------------------

  def test_user_can_define_self_namespace
    # The reserved guard is gone - users can use :self freely.
    klass = Class.new(Hammer) do
      namespace :self do
        task :foo do
          desc 'mine'
          proc { |_| }
        end
      end
    end
    assert klass.namespaces.key?('self')
  end

  # ----- recipes task: dispatch -------------------------------------

  def test_recipes_lists_when_no_action_flag
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'recipes']) }
      # srt is bundled with the gem so the listing must mention it.
      assert_includes out, 'srt'
    end
  end

  def test_recipes_install_prints_stub
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'recipes', '--install', 'srt']) }
      assert_includes out, "Hammer.recipe('srt', ARGV)"
      assert_includes out, '#!/usr/bin/env ruby'
    end
  end

  def test_recipes_install_with_target_writes_and_chmods
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'srt')
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        out, = capture { Hammer.cli(['--system', 'recipes', '--install', 'srt', target]) }
        assert_includes out, "installed srt -> #{target}"
      end
      assert File.exist?(target)
      assert File.executable?(target)
      assert_includes File.read(target), "Hammer.recipe('srt', ARGV)"
    end
  end

  def test_recipes_install_with_target_expands_tilde
    Dir.mktmpdir do |home|
      bin = File.join(home, 'bin')
      Dir.mkdir(bin)
      orig_home = ENV['HOME']
      ENV['HOME'] = home
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        capture { Hammer.cli(['--system', 'recipes', '--install', 'srt', '~/bin/srt']) }
      end
      assert File.exist?(File.join(bin, 'srt'))
    ensure
      ENV['HOME'] = orig_home
    end
  end

  def test_recipes_path_prints_path
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'recipes', '--path', 'srt']) }
      assert_includes out, 'recipes/srt.rb'
    end
  end

  def test_recipes_show_cats_source
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'recipes', '--show', 'srt']) }
      assert_includes out, '# desc:'
      assert_includes out, 'task :'
    end
  end

  def test_recipes_show_without_name_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['--system', 'recipes', '--show']) }
      assert_equal 1, status
      assert_includes err, 'missing recipe name'
    end
  end

  def test_recipes_run_dispatches_to_recipe
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'echo.rb'), <<~RUBY)
        # desc: echo recipe
        task :hi do
          desc 'say hi'
          proc { say 'reached the recipe' }
        end
      RUBY
      ENV['HAMMER_RECIPES_DIR'] = dir
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        out, = capture { Hammer.cli(['--system', 'recipes', '--run', 'echo', 'hi']) }
        assert_includes out, 'reached the recipe'
      end
    ensure
      ENV.delete('HAMMER_RECIPES_DIR')
    end
  end

  def test_recipes_run_without_name_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['--system', 'recipes', '--run']) }
      assert_equal 1, status
      assert_includes err, 'missing recipe name'
    end
  end

  # ----- --system flag ----------------------------------------------

  def test_system_flag_reaches_recipes_inside_a_project
    # With a Hammerfile present, `hammer recipes` would normally dispatch
    # to a user-defined task (here :x exists, :recipes does not, so it'd
    # error). `--system` bypasses the Hammerfile entirely so the built-in
    # is reachable.
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'recipes']) }
      assert_includes out, 'srt'
    end
  end

  def test_recipes_not_registered_when_hammerfile_present
    # Without --system, the :recipes built-in is NOT registered when a
    # Hammerfile is present - keeps the user's root namespace clean.
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['recipes']) }
      assert_equal 1, status
      assert_includes err, 'unknown'
    end
  end

  def test_init_not_registered_when_hammerfile_present
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['init']) }
      assert_equal 1, status
      assert_includes err, 'unknown'
    end
  end

  # ----- update task ------------------------------------------------

  def test_update_task_calls_self_update
    called = false
    Hammer.singleton_class.send(:alias_method, :__orig_self_update, :self_update)
    Hammer.define_singleton_method(:self_update) { called = true }

    with_hammerfile("task :x do; proc { |_| }; end\n") do
      capture { Hammer.cli(['update']) }
    end
    assert called, '`hammer update` should call Hammer.self_update'
  ensure
    Hammer.define_singleton_method(:self_update) { __orig_self_update }
    Hammer.singleton_class.send(:remove_method, :__orig_self_update) if Hammer.singleton_class.method_defined?(:__orig_self_update)
  end

  # ----- Recipes: section visibility --------------------------------

  HF ||= "task :x do; desc 'X'; proc { |_| }; end\n" \
         "namespace :gem do; task :build do; desc 'B'; proc { |_| }; end; end\n"

  def test_bare_hammer_hides_recipes_section
    with_hammerfile(HF) do
      out, = capture { Hammer.cli([]) }
      refute_includes out, 'Recipes:'
    end
  end

  def test_help_flag_shows_recipes_section
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'Recipes:'
      assert_includes out, 'srt'
    end
  end

  def test_namespace_listing_hides_recipes_section
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['gem:']) }
      refute_includes out, 'Recipes:'
      refute_includes out, 'srt'
    end
  end

  def test_user_cli_never_shows_recipes_section
    # Subclassing Hammer directly (no @hammer_binary flag) must never
    # surface the binary-only sections, even under --help.
    klass = Class.new(Hammer) do
      task :hello do
        desc 'greet'
        proc { |_| }
      end
    end
    out, = capture { klass.start(['--help']) }
    refute_includes out, 'Recipes:'
  end

  # ----- hidden core built-ins (project context) --------------------

  def test_register_core_hidden_blanks_core_descs
    klass = Class.new(Hammer)
    Hammer::Builtins.register_core(klass, hidden: true)
    Hammer::Builtins::CORE_HIDEABLE.each do |name|
      assert klass.commands.key?(name), "missing :#{name} after hidden register_core"
      assert_empty klass.commands[name].desc, ":#{name} should have a blank desc when hidden"
    end
  end

  def test_register_core_without_hidden_keeps_descs
    klass = Class.new(Hammer)
    Hammer::Builtins.register_core(klass)
    refute_empty klass.commands['update'].desc
    refute_empty klass.commands['version'].desc
  end

  def test_register_core_hidden_keeps_user_defined_desc
    # A Hammerfile that redefines :help must keep its own desc - we only
    # blank the built-ins we just registered.
    klass = Class.new(Hammer) do
      task :help do
        desc 'my help'
        proc { |_| }
      end
    end
    Hammer::Builtins.register_core(klass, hidden: true)
    assert_equal 'my help', klass.commands['help'].desc
  end

  def test_project_listing_hides_core_builtins
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli([]) }
      assert_includes out, 'build it'                 # project task shows
      refute_includes out, 'Rebuild + reinstall'      # :update desc
      refute_includes out, 'Print lux-hammer version' # :version desc
      refute_includes out, 'AGENTS.md'                # :agents desc
    end
  end

  def test_project_core_builtins_still_dispatch
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['version']) }
      assert_includes out, Hammer::VERSION
    end
  end

  def test_no_hammerfile_listing_keeps_core_builtins
    # Outside a project the built-ins are the whole CLI - they must stay
    # visible (hidden: false on the no-Hammerfile branch).
    with_no_hammerfile do
      out, = capture { Hammer.cli([]) }
      assert_includes out, 'Rebuild + reinstall'      # :update desc
      assert_includes out, 'Print lux-hammer version' # :version desc
    end
  end
end

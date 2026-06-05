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

  def test_looks_like_builtin_for_h_namespace
    assert Hammer.looks_like_builtin?(['h'])
    assert Hammer.looks_like_builtin?(['h:'])
    assert Hammer.looks_like_builtin?(['h:update'])
    assert Hammer.looks_like_builtin?(['h:recipes'])
    refute Hammer.looks_like_builtin?(['update'])  # old root name is gone
    refute Hammer.looks_like_builtin?(['build'])
    refute Hammer.looks_like_builtin?([])
  end

  # ----- register ----------------------------------------------------

  def test_register_adds_default_at_root_and_builtins_under_h
    klass = Class.new(Hammer)
    Hammer::Builtins.register(klass)
    assert klass.commands.key?('default'), 'missing root :default'
    h = klass.namespaces['h']
    refute_nil h, 'missing :h namespace'
    %w[help update agents version recipes init].each do |name|
      assert h.commands.key?(name), "missing h:#{name} after register"
    end
  end

  def test_register_skips_when_user_defined
    klass = Class.new(Hammer) do
      task :default do
        proc { |_| say 'mine' }
      end
      namespace :h do
        task :update do
          desc 'my update'
          proc { |_| say 'my update' }
        end
      end
    end
    Hammer::Builtins.register(klass)
    assert_equal 'my update', klass.namespaces['h'].commands['update'].desc
  end

  # ----- :h is the reserved built-in namespace; :self is free --------

  def test_user_can_define_self_namespace
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
      out, = capture { Hammer.cli(['--system', 'h:recipes']) }
      # srt is bundled with the gem so the listing must mention it.
      assert_includes out, 'srt'
    end
  end

  def test_recipes_install_prints_stub
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'h:recipes', '--install', 'srt']) }
      assert_includes out, "Hammer.recipe('srt', ARGV)"
      assert_includes out, '#!/usr/bin/env ruby'
    end
  end

  def test_recipes_install_with_target_writes_and_chmods
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'srt')
      with_hammerfile("task :x do; proc { |_| }; end\n") do
        out, = capture { Hammer.cli(['--system', 'h:recipes', '--install', 'srt', target]) }
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
        capture { Hammer.cli(['--system', 'h:recipes', '--install', 'srt', '~/bin/srt']) }
      end
      assert File.exist?(File.join(bin, 'srt'))
    ensure
      ENV['HOME'] = orig_home
    end
  end

  def test_recipes_path_prints_path
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'h:recipes', '--path', 'srt']) }
      assert_includes out, 'recipes/srt.rb'
    end
  end

  def test_recipes_show_cats_source
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--system', 'h:recipes', '--show', 'srt']) }
      assert_includes out, '# desc:'
      assert_includes out, 'task :'
    end
  end

  def test_recipes_show_without_name_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['--system', 'h:recipes', '--show']) }
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
        out, = capture { Hammer.cli(['--system', 'h:recipes', '--run', 'echo', 'hi']) }
        assert_includes out, 'reached the recipe'
      end
    ensure
      ENV.delete('HAMMER_RECIPES_DIR')
    end
  end

  def test_recipes_run_without_name_errors
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['--system', 'h:recipes', '--run']) }
      assert_equal 1, status
      assert_includes err, 'missing recipe name'
    end
  end

  # ----- h: built-ins inside a project ------------------------------

  def test_h_recipes_reachable_inside_a_project
    # The built-ins live under `h:`, so they're reachable inside a
    # project without `--system` and never collide with root tasks.
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['h:recipes']) }
      assert_includes out, 'srt'
    end
  end

  def test_old_root_names_are_gone
    # Hard switch: the pre-namespace root names no longer resolve.
    with_hammerfile("task :x do; proc { |_| }; end\n") do
      _, err, status = capture_exit { Hammer.cli(['recipes']) }
      assert_equal 1, status
      assert_includes err, 'unknown'
    end
  end

  def test_old_init_root_name_is_gone
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
      capture { Hammer.cli(['h:update']) }
    end
    assert called, '`hammer h:update` should call Hammer.self_update'
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

  # ----- h: built-ins in listings -----------------------------------

  def test_bare_listing_hides_h_builtins
    # The bare-invocation listing stays focused on project tasks - the
    # `h:` built-ins are pruned (but still dispatchable).
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli([]) }
      assert_includes out, 'build it'          # project task shows
      refute_includes out, 'h:update'          # built-ins hidden outside --help
    end
  end

  def test_help_listing_shows_h_builtins
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'build it'          # project task shows
      assert_includes out, 'h:update'          # built-ins surface under --help
      assert_includes out, 'h:version'
    end
  end

  def test_project_h_builtins_dispatch
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['h:version']) }
      assert_includes out, Hammer::VERSION
    end
  end

  def test_h_namespace_listing
    with_hammerfile("task :build do; desc 'build it'; proc { |_| }; end\n") do
      out, = capture { Hammer.cli(['h:']) }
      assert_includes out, 'h:update'
      assert_includes out, 'h:recipes'
      refute_includes out, 'build it'          # only the namespace's own tasks
    end
  end

  def test_no_hammerfile_help_lists_h_builtins
    # Outside a project the built-ins are the whole CLI - they surface in
    # the extended `--help` view (bare invocation stays terse).
    with_no_hammerfile do
      out, = capture { Hammer.cli(['--help']) }
      assert_includes out, 'h:update'
      assert_includes out, 'h:version'
    end
  end
end

require_relative 'test_helper'

class DslTest < Minitest::Test
  include CaptureIO

  # ----- class DSL ----------------------------------------------------

  def build_cli(&block)
    Class.new(Hammer) do
      instance_eval(&block)
    end
  end

  def test_def_style_command
    captured = nil
    cli = Class.new(Hammer) do
      desc 'Build'
      opt :env, default: 'dev'
      define_method(:build) { |opts| captured = opts }
    end
    capture { cli.start(%w[build prod]) }
    assert_equal 'prod', captured[:env]
  end

  def test_def_style_alt_and_example
    cli = Class.new(Hammer) do
      desc 'Server'
      example 'server -p 4000'
      alt :s
      define_method(:server) { |opts| }
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli server'
    assert_includes out, '(alt: s)'
    assert_includes out, 'Server'
  end

  def test_def_with_no_args_is_called_without_opts
    log = []
    cli = Class.new(Hammer) do
      desc 'Ping'
      define_method(:ping) { log << :pong }
    end
    capture { cli.start(['ping']) }
    assert_equal [:pong], log
  end

  def test_def_without_desc_is_just_a_method
    cli = Class.new(Hammer) do
      define_method(:helper) { 42 }
    end
    refute cli.commands.key?('helper')
  end

  def test_def_and_define_can_coexist
    log = []
    cli = Class.new(Hammer) do
      desc 'def-style command'
      define_method(:foo) { |_| log << :foo }

      task :bar do
        desc 'block-style command'
        proc { |_| log << :bar }
      end
    end
    capture { cli.start(['foo']) }
    capture { cli.start(['bar']) }
    assert_equal [:foo, :bar], log
  end

  def test_pending_desc_does_not_leak_across_define
    log = []
    cli = Class.new(Hammer) do
      desc 'should be cleared'
      task :first do
        proc { |_| log << :first }
      end
      # No desc here - foo should NOT become a command
      define_method(:foo) { |_| log << :foo }
    end
    refute cli.commands.key?('foo')
    assert cli.commands.key?('first')
  end

  def test_define_registers_command
    captured = nil
    cli = build_cli do
      task :build do
        desc 'Build'
        opt :env, default: 'dev'
        proc { |opts| captured = opts }
      end
    end
    capture { cli.start(%w[build --env=prod a b]) }
    refute_nil captured
    assert_equal 'prod', captured[:env]
    assert_equal %w[a b], captured[:args]
  end

  def test_opts_all_symbol_keys
    seen = nil
    cli = build_cli do
      task :x do
        opt :env, default: 'dev'
        opt :loud, type: :boolean
        proc { |opts| seen = opts }
      end
    end
    capture { cli.start(%w[x --env=prod --loud foo]) }
    assert_equal [:env, :loud, :args, :stdin], seen.keys
    assert(seen.keys.all? { |k| k.is_a?(Symbol) })
    assert_equal 'prod', seen[:env]
    assert_equal true,   seen[:loud]
    assert_equal ['foo'], seen[:args]
    assert_nil seen[:stdin]
  end

  def test_block_must_end_with_proc
    err = assert_raises(Hammer::Error) do
      build_cli { task(:bad) { desc 'no proc here' } }
    end
    assert_includes err.message, 'must end with'
  end

  def test_missing_proc_error_includes_example
    err = assert_raises(Hammer::Error) do
      build_cli { task(:greet) { desc 'hi' } }
    end
    assert_includes err.message, 'Example:'
    assert_includes err.message, 'task :greet do'
    assert_includes err.message, 'proc do |opts|'
  end

  def test_help_groups_by_namespace
    cli = build_cli do
      task :build do
        desc 'Build'
        proc { |_| }
      end
      namespace :db do
        task :migrate do
          desc 'Migrate'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['help']) }
    # commands section appears before db: section
    cmd_idx = out.index('Commands:')
    db_idx  = out.index("db:\n")
    refute_nil cmd_idx
    refute_nil db_idx
    assert cmd_idx < db_idx
  end

  def test_option_help_shows_default_and_required
    cli = build_cli do
      task :run do
        opt :env, default: 'dev'
        opt :url, req: true
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help run]) }
    assert_includes out, '(default: "dev")'
    assert_includes out, '(required)'
  end

  def test_command_usage_shows_positional_opt_names
    cli = build_cli do
      task :deploy do
        opt :url, req: true
        opt :env
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help deploy]) }
    assert_includes out, 'mycli deploy URL [ENV] [OPTIONS]'
  end

  def test_alt_dispatches
    hits = []
    cli = build_cli do
      task :server do
        alt :s, :srv
        proc { |_| hits << :ran }
      end
    end
    capture { cli.start(['server']) }
    capture { cli.start(['s']) }
    capture { cli.start(['srv']) }
    assert_equal [:ran, :ran, :ran], hits
  end

  def test_unknown_command_exits_1
    cli = build_cli { task(:x) { proc { |_| } } }
    _, err, status = capture_exit { cli.start(['bogus']) }
    assert_equal 1, status
    assert_includes err, 'unknown command'
  end

  def test_help_prints_github_footer
    cli = build_cli { task(:x) { desc 'X'; proc { |_| } } }
    out, = capture { cli.start(['help']) }
    assert_includes out, 'powered by hammer'
    assert_includes out, 'https://github.com/dux/hammer'
  end

  def test_help_lists_commands_with_alts
    cli = build_cli do
      task :build do
        desc 'Build'
        proc { |_| }
      end
      task :server do
        desc 'Server'
        alt :s
        proc { |_| }
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli build'
    assert_includes out, 'mycli server'
    assert_includes out, '(alt: s)'
    assert_includes out, 'Build'
    assert_includes out, 'Server'
  end

  def test_per_command_help
    cli = build_cli do
      task :build do
        desc 'Build the project'
        example 'build -v'
        opt :verbose, type: :boolean, alias: :v
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help build]) }
    assert_includes out, 'Build the project'
    assert_includes out, '--verbose'
    assert_includes out, '-v'
    assert_includes out, 'Examples:'
    assert_includes out, 'mycli build -v'
  end

  def test_multi_line_desc_lists_only_brief
    cli = build_cli do
      task :build do
        desc "Build the project\nextra detail not shown in listing"
        proc { |_| }
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, '# Build the project'
    refute_includes out, 'extra detail not shown in listing'
  end

  def test_multi_line_desc_shows_full_in_command_help
    cli = build_cli do
      task :build do
        desc <<~TEXT
          Build the project.

          Compiles assets and produces a tarball under tmp/.
        TEXT
        proc { |_| }
      end
    end
    out, = capture { cli.start(%w[help build]) }
    assert_includes out, '  Build the project.'
    assert_includes out, '  Compiles assets and produces a tarball under tmp/.'
  end

  def test_help_via_dash_h
    cli = build_cli { task(:x) { desc 'X'; proc { |_| } } }
    out, = capture { cli.start(['-h']) }
    assert_includes out, 'Usage:'
  end

  def test_dash_h_after_command_shows_command_help
    ran = false
    cli = build_cli do
      task :build do
        desc 'Build the project'
        opt :env, default: 'dev'
        proc { |_| ran = true }
      end
    end
    out, = capture { cli.start(%w[build -h]) }
    assert_includes out, 'Usage: mycli build'
    assert_includes out, 'Build the project'
    refute ran, 'handler must not run when -h is present'
  end

  def test_long_help_flag_after_command
    ran = false
    cli = build_cli do
      task :build do
        proc { |_| ran = true }
      end
    end
    capture { cli.start(%w[build --help]) }
    refute ran
  end

  def test_help_after_namespaced_command_shows_full_path
    cli = build_cli do
      namespace :gem do
        task :inc_version do
          desc 'Bump version'
          opt :bump, default: 'patch'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(%w[gem:inc_version -h]) }
    assert_includes out, 'Usage: mycli gem:inc_version'
  end

  def test_parser_error_help_uses_full_path
    cli = build_cli do
      namespace :gem do
        task :inc_version do
          opt :bump
          proc { |_| }
        end
      end
    end
    out, err, _ = capture_exit { cli.start(%w[gem:inc_version --bogus]) }
    assert_includes err, 'unknown option'
    assert_includes out, 'mycli gem:inc_version'
  end

  def test_double_dash_keeps_minus_h_as_positional
    captured = nil
    cli = build_cli do
      task :x do
        proc { |opts| captured = opts[:args] }
      end
    end
    capture { cli.start(['x', '--', '-h']) }
    assert_equal ['-h'], captured
  end

  def test_help_flag_as_opt_name_raises
    assert_raises(Hammer::Error) do
      Hammer::Option.new(:help)
    end
  end

  def test_help_flag_as_alias_raises
    assert_raises(Hammer::Error) do
      Hammer::Option.new(:host, alias: :h)
    end
  end

  def test_namespace_dispatch_via_colon_path
    captured = nil
    cli = build_cli do
      namespace :db do
        task :migrate do
          proc { |opts| captured = opts[:args] }
        end
      end
    end
    capture { cli.start(%w[db:migrate 3]) }
    assert_equal ['3'], captured
  end

  def test_help_lists_namespaced_commands_with_colons
    cli = build_cli do
      task :build do
        desc 'Build'
        proc { |_| }
      end
      namespace :db do
        task :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'mycli build'
    assert_includes out, 'mycli db:migrate'
  end

  def test_help_for_namespace_lists_contents
    cli = build_cli do
      namespace :db do
        task :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(%w[help db]) }
    assert_includes out, 'mycli db:migrate'
  end

  def test_bare_namespace_is_implicit_help
    cli = build_cli do
      namespace :db do
        task :migrate do
          desc 'Run migrations'
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['db']) }
    assert_includes out, 'mycli db:migrate'
  end

  def test_nested_namespace_dispatch
    captured = nil
    cli = build_cli do
      namespace :db do
        namespace :users do
          task :list do
            proc { |opts| captured = opts[:args] }
          end
        end
      end
    end
    capture { cli.start(%w[db:users:list active admins]) }
    assert_equal %w[active admins], captured
  end

  def test_hammer_invokes_command_from_proc
    log = []
    cli = build_cli do
      task :build do
        opt :env, default: 'dev'
        proc { |opts| log << [:build, opts[:env]] }
      end
      task :deploy do
        proc do |_|
          hammer :build, env: 'prod'
          log << [:deploy]
        end
      end
    end
    capture { cli.start(['deploy']) }
    assert_equal [[:build, 'prod'], [:deploy]], log
  end

  def test_hammer_resolves_namespaced_via_colon_string
    log = []
    cli = build_cli do
      namespace :db do
        namespace :users do
          task :list do
            proc { |opts| log << opts[:args] }
          end
        end
      end
    end
    capture { cli.hammer 'db:users:list', 'a', 'b' }
    assert_equal [%w[a b]], log
  end

  def test_hammer_cross_invoke_from_inside_namespaced_command
    log = []
    cli = build_cli do
      namespace :gem do
        task :build do
          proc { |_| log << :build }
        end
        task :publish do
          proc do |_|
            hammer 'gem:build'
            log << :publish
          end
        end
      end
    end
    capture { cli.start(['gem:publish']) }
    assert_equal [:build, :publish], log
  end

  def test_hammer_opts_become_flags
    captured = nil
    cli = build_cli do
      task :show do
        opt :env
        opt :loud, type: :boolean
        proc { |opts| captured = opts }
      end
    end
    capture { cli.hammer :show, env: 'prod', loud: true }
    assert_equal 'prod', captured[:env]
    assert_equal true,   captured[:loud]
  end

  def test_hammer_no_prefix_opt_is_own_flag
    captured = nil
    cli = build_cli do
      task :show do
        opt :no_reset, type: :boolean
        proc { |opts| captured = opts[:no_reset] }
      end
    end
    capture { cli.hammer :show, no_reset: true }
    assert_equal true, captured
  end

  def test_hammer_false_opt_is_noop
    captured = nil
    cli = build_cli do
      task :show do
        opt :cache, type: :boolean, default: true
        proc { |opts| captured = opts[:cache] }
      end
    end
    capture { cli.hammer :show, cache: false }
    # default sticks - false-valued opts are skipped entirely
    assert_equal true, captured
  end

  def test_hammer_underscore_in_opt_becomes_dash
    captured = nil
    cli = build_cli do
      task :show do
        opt :dry_run, type: :boolean
        proc { |opts| captured = opts[:dry_run] }
      end
    end
    capture { cli.hammer :show, dry_run: true }
    assert_equal true, captured
  end

  def test_hammer_works_with_no_opts
    log = []
    cli = build_cli do
      task :run do
        proc { |_| log << :ran }
      end
    end
    capture { cli.hammer :run }
    assert_equal [:ran], log
  end

  def test_unknown_method_still_raises
    cli = build_cli { task(:x) { proc { |_| } } }
    assert_raises(NoMethodError) { cli.something_else }
  end

  # ----- chain separator ----------------------------------------------

  def test_chain_separator_runs_each_segment_in_order
    log = []
    cli = build_cli do
      task(:foo) { proc { |_| log << :foo } }
      task(:bar) { proc { |_| log << :bar } }
      task(:baz) { proc { |_| log << :baz } }
    end
    capture { cli.start(%w[foo + bar + baz]) }
    assert_equal %i[foo bar baz], log
  end

  def test_chain_forwards_args_and_flags_per_segment
    captured = []
    cli = build_cli do
      task :build do
        opt :env, default: 'dev'
        proc { |opts| captured << [:build, opts[:env], opts[:args]] }
      end
      task :ship do
        opt :force, type: :boolean
        proc { |opts| captured << [:ship, opts[:force], opts[:args]] }
      end
    end
    capture { cli.start(%w[build prod + ship --force a b]) }
    assert_equal [[:build, 'prod', []], [:ship, true, %w[a b]]], captured
  end

  def test_chain_escape_double_plus_yields_literal_plus_arg
    captured = nil
    cli = build_cli do
      task :echo do
        proc { |opts| captured = opts[:args] }
      end
    end
    capture { cli.start(['echo', '++', 'x']) }
    assert_equal ['+', 'x'], captured
  end

  def test_chain_does_not_split_inside_quoted_opt_value
    # Simulates `hammer echo --foo="a + b"` - shell delivers one token.
    captured = nil
    cli = build_cli do
      task :echo do
        opt :foo
        proc { |opts| captured = opts[:foo] }
      end
    end
    capture { cli.start(['echo', '--foo=a + b']) }
    assert_equal 'a + b', captured
  end

  def test_chain_needs_dedupes_across_segments
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
      task :build do
        needs :env
        proc { |_| log << :build }
      end
      task :deploy do
        needs :env
        proc { |_| log << :deploy }
      end
    end
    capture { cli.start(%w[build + deploy]) }
    assert_equal %i[env build deploy], log
  end

  def test_alt_inside_namespace
    captured = nil
    cli = build_cli do
      namespace :db do
        task :migrate do
          alt :m
          proc { |opts| captured = opts[:args] }
        end
      end
    end
    capture { cli.start(%w[db:m 5]) }
    assert_equal ['5'], captured
  end

  def test_error_inside_proc_exits_1_with_message
    cli = build_cli do
      task :doomed do
        proc { |_| error 'boom' }
      end
    end
    out, err, status = capture_exit { cli.start(['doomed']) }
    assert_equal 1, status
    assert_includes err, 'boom'
    assert_includes err, '[error]'
    # no command help spam on user-raised errors
    refute_includes out, 'Usage:'
  end

  def test_parser_error_exits_1
    cli = build_cli do
      task :x do
        opt :env, type: :string, req: true
        proc { |_| }
      end
    end
    _, err, status = capture_exit { cli.start(['x']) }
    assert_equal 1, status
    assert_includes err, 'missing required'
  end

  # ----- block DSL ----------------------------------------------------

  def test_block_dsl_run
    captured = nil
    capture do
      Hammer.run(%w[hello dino -l]) do
        task :hello do
          opt :loud, type: :boolean, alias: :l
          proc { |opts| captured = opts }
        end
      end
    end
    assert_equal true, captured[:loud]
    assert_equal ['dino'], captured[:args]
  end

  def test_helpers_block_attaches_methods_visible_to_procs
    captured = nil
    capture do
      Hammer.run(%w[run]) do
        helpers do
          private

          def shout(msg)
            "#{msg}!".upcase
          end
        end

        task :run do
          proc { captured = shout('hi') }
        end
      end
    end
    assert_equal 'HI!', captured
  end

  def test_helpers_block_can_use_shell_helpers_inside
    out, = capture do
      Hammer.run(%w[run]) do
        helpers do
          private

          def greet
            say 'hello from helper'
          end
        end

        task :run do
          proc { greet }
        end
      end
    end
    assert_includes out, 'hello from helper'
  end

  # ----- default program_name -----------------------------------------

  def with_program_name(value)
    original = $PROGRAM_NAME
    $PROGRAM_NAME = value
    yield
  ensure
    $PROGRAM_NAME = original
  end

  def test_default_program_name_is_basename_when_bin_is_in_path
    with_program_name('lux') do
      cli = Class.new(Hammer)
      assert_equal 'lux', cli.program_name
    end
  end

  def test_default_program_name_is_basename_when_bin_is_outside_cwd
    with_program_name('/usr/local/bin/lux') do
      cli = Class.new(Hammer)
      assert_equal 'lux', cli.program_name
    end
  end

  def test_default_program_name_is_relative_when_bin_is_inside_cwd
    Dir.mktmpdir do |dir|
      bin = File.join(dir, 'bin', 'foo')
      FileUtils.mkdir_p(File.dirname(bin))
      File.write(bin, '')
      Dir.chdir(dir) do
        with_program_name('bin/foo') do
          cli = Class.new(Hammer)
          assert_equal 'bin/foo', cli.program_name
        end
        with_program_name('./bin/foo') do
          cli = Class.new(Hammer)
          assert_equal 'bin/foo', cli.program_name
        end
        with_program_name(bin) do
          cli = Class.new(Hammer)
          assert_equal 'bin/foo', cli.program_name
        end
      end
    end
  end

  # ----- before hooks ------------------------------------------------

  def test_before_runs_at_root_scope
    log = []
    cli = build_cli do
      before { log << :root }
      task :x do
        proc { |_| log << :cmd }
      end
    end
    capture { cli.start(['x']) }
    assert_equal [:root, :cmd], log
  end

  def test_before_runs_outer_then_inner_for_nested_namespaces
    log = []
    cli = build_cli do
      before { log << :root }
      namespace :db do
        before { log << :db }
        namespace :users do
          before { log << :users }
          task :list do
            proc { |_| log << :cmd }
          end
        end
      end
    end
    capture { cli.start(%w[db:users:list]) }
    assert_equal [:root, :db, :users, :cmd], log
  end

  def test_before_only_fires_for_commands_in_its_subtree
    log = []
    cli = build_cli do
      namespace :db do
        before { log << :db }
        task :migrate do
          proc { |_| log << :migrate }
        end
      end
      task :build do
        proc { |_| log << :build }
      end
    end
    capture { cli.start(['build']) }
    assert_equal [:build], log
    log.clear
    capture { cli.start(['db:migrate']) }
    assert_equal [:db, :migrate], log
  end

  def test_before_can_call_hammer_helpers
    log = []
    cli = build_cli do
      task :setup do
        proc { |_| log << :setup }
      end
      namespace :db do
        before { hammer :setup }
        task :migrate do
          proc { |_| log << :migrate }
        end
      end
    end
    capture { cli.start(['db:migrate']) }
    assert_equal [:setup, :migrate], log
  end

  def test_multiple_before_blocks_in_same_scope_run_in_order
    log = []
    cli = build_cli do
      namespace :db do
        before { log << :one }
        before { log << :two }
        task :x do
          proc { |_| log << :cmd }
        end
      end
    end
    capture { cli.start(['db:x']) }
    assert_equal [:one, :two, :cmd], log
  end

  def test_before_in_block_dsl
    log = []
    capture do
      Hammer.run(['x']) do
        before { log << :hook }
        task :x do
          proc { |_| log << :cmd }
        end
      end
    end
    assert_equal [:hook, :cmd], log
  end

  def test_before_fires_once_even_with_needs
    log = []
    cli = build_cli do
      before { log << :hook }
      task :env do
        proc { |_| log << :env }
      end
      task :app do
        needs :env
        proc { |_| log << :app }
      end
    end
    capture { cli.start(['app']) }
    assert_equal [:hook, :env, :app], log
  end

  def test_before_receives_opts
    captured = nil
    cli = build_cli do
      before { |opts| captured = opts }
      task :x do
        opt :env, default: 'dev'
        proc { |_| }
      end
    end
    capture { cli.start(%w[x --env=prod]) }
    assert_equal 'prod', captured[:env]
  end

  # ----- hidden (empty-desc) commands --------------------------------

  def test_command_without_desc_is_hidden_from_root_listing
    cli = build_cli do
      task :visible do
        desc 'shown'
        proc { |_| }
      end
      task :env do
        proc { |_| }
      end
    end
    out, = capture { cli.start(['help']) }
    assert_includes out, 'visible'
    refute_includes out, 'mycli env'
  end

  def test_hidden_command_is_still_dispatchable
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
    end
    capture { cli.start(['env']) }
    assert_equal [:env], log
  end

  def test_hidden_command_callable_via_hammer_helper
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
      task :run do
        desc 'run'
        proc do |_|
          hammer :env
          log << :run
        end
      end
    end
    capture { cli.start(['run']) }
    assert_equal [:env, :run], log
  end

  def test_hidden_command_inside_namespace_is_hidden_in_namespace_help
    cli = build_cli do
      namespace :db do
        task :migrate do
          desc 'shown'
          proc { |_| }
        end
        task :env do
          proc { |_| }
        end
      end
    end
    out, = capture { cli.start(['db']) }
    assert_includes out, 'db:migrate'
    refute_includes out, 'db:env'
  end

  # ----- needs (prereqs) ---------------------------------------------

  def test_needs_runs_prereq_before_command
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
      task :app do
        needs :env
        proc { |_| log << :app }
      end
    end
    capture { cli.start(['app']) }
    assert_equal [:env, :app], log
  end

  def test_needs_fires_each_prereq_once_per_invocation
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
      task :build do
        needs :env
        proc { |_| log << :build }
      end
      task :app do
        needs :env, :build
        proc { |_| log << :app }
      end
    end
    capture { cli.start(['app']) }
    assert_equal [:env, :build, :app], log
  end

  def test_needs_resolves_namespaced_paths
    log = []
    cli = build_cli do
      namespace :db do
        task :env do
          proc { |_| log << :db_env }
        end
      end
      task :app do
        needs 'db:env'
        proc { |_| log << :app }
      end
    end
    capture { cli.start(['app']) }
    assert_equal [:db_env, :app], log
  end

  def test_needs_raises_on_unknown_prereq
    cli = build_cli do
      task :app do
        needs :missing
        proc { |_| }
      end
    end
    _, err, status = capture_exit { cli.start(['app']) }
    assert_equal 1, status
    assert_includes err, "unknown command 'missing'"
  end

  def test_needs_in_def_style_command
    log = []
    cli = Class.new(Hammer) do
      desc 'env'
      define_method(:env) { |_| log << :env }

      desc 'app'
      needs :env
      define_method(:app) { |_| log << :app }
    end
    capture { cli.start(['app']) }
    assert_equal [:env, :app], log
  end

  def test_needs_does_not_leak_across_define
    log = []
    cli = build_cli do
      task :env do
        proc { |_| log << :env }
      end
      # needs declared but no consuming `def` -> must be cleared
      needs :env
      task :first do
        proc { |_| log << :first }
      end
      task :second do
        proc { |_| log << :second }
      end
    end
    capture { cli.start(['first']) }
    capture { cli.start(['second']) }
    assert_equal [:first, :second], log
  end

  # ----- cron ---------------------------------------------------------

  def test_cron_sets_schedule_metadata
    cli = build_cli do
      task :backup do
        desc 'Nightly backup'
        cron '@daily'
        proc { |_| }
      end
    end
    cmd = cli.commands['backup']
    assert_equal '@daily', cmd.cron
    assert_kind_of Hammer::Cron, cmd.cron_schedule
  end

  def test_cron_invalid_expression_fails_at_definition
    err = assert_raises(Hammer::Error) do
      build_cli do
        task :backup do
          cron '99 * * * *'
          proc { |_| }
        end
      end
    end
    assert_match(/minute/, err.message)
  end

  def test_cron_in_def_style_command
    cli = Class.new(Hammer) do
      desc 'Tick'
      cron '10m'
      define_method(:tick) { |_| }
    end
    assert_equal '10m', cli.commands['tick'].cron
    assert_equal 600, cli.commands['tick'].cron_schedule.interval
  end

  def test_cron_does_not_leak_across_tasks
    cli = build_cli do
      task :scheduled do
        cron '5m'
        proc { |_| }
      end
      task :plain do
        proc { |_| }
      end
    end
    assert_nil cli.commands['plain'].cron
  end

  def test_cron_shows_in_command_help
    cli = build_cli do
      task :backup do
        desc 'Nightly backup'
        cron '@daily'
        proc { |_| }
      end
    end
    out, = capture { cli.start(['backup', '-h']) }
    assert_includes out, 'cron: @daily'
  end

  def test_block_dsl_alt
    hits = []
    capture do
      Hammer.run(['s']) do
        task :server do
          alt :s
          proc { |_| hits << :ok }
        end
      end
    end
    assert_equal [:ok], hits
  end
end

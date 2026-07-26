require_relative 'test_helper'
require 'json'

class JsonExportTest < Minitest::Test
  include CaptureIO

  HF = <<~RUBY
    desc 'My tools'
    task :build do
      desc 'Build the project'
      example 'build --env=prod'
      alt :b
      needs :env
      cron '*/5 * * * *'
      opt :env,     default: 'dev', desc: 'target env'
      opt :verbose, type: :boolean, alias: :v, desc: 'noisy'
      proc { |_| }
    end
    task :env do
      proc { |_| }                       # hidden: no desc
    end
    namespace :db do
      task :migrate do
        desc 'Run migrations'
        opt :step, type: :integer, default: 1
        proc { |_| }
      end
    end
  RUBY

  # `foo` shares its name with the `foo:` namespace - it must group
  # under "foo" alongside `foo:bar`, never "__root".
  HF_SIBLING = <<~RUBY
    task :foo do
      desc 'bare foo'
      proc { |_| }
    end
    namespace :foo do
      task :bar do
        desc 'foo bar'
        proc { |_| }
      end
    end
  RUBY

  def with_hammerfile(content)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'Hammerfile'), content)
      Dir.chdir(dir) { yield dir }
    end
  end

  # The run banner now goes to stderr, so stdout is clean JSON.
  def spec(argv = ['h:json'])
    out, = capture { Hammer.cli(argv) }
    JSON.parse(out)
  end

  def test_grouped_shape
    with_hammerfile(HF) do
      s = spec
      assert_equal 1, s['schema']
      assert_equal 'My tools', s['app_desc']
      assert s['commands']['__root'].key?('build')
      assert s['commands']['db'].key?('db:migrate')
    end
  end

  def test_task_and_option_meta
    with_hammerfile(HF) do
      b = spec['commands']['__root']['build']
      assert_equal 'Build the project', b['desc']
      assert_equal ['b'], b['alts']
      assert_equal ['env'], b['needs']
      assert_equal '*/5 * * * *', b['cron']
      assert_includes b['examples'], 'build --env=prod'

      m = spec['commands']['db']['db:migrate']
      assert_nil m['cron']   # unscheduled tasks export cron: null

      env = b['options'].find { |o| o['name'] == 'env' }
      assert_equal 'string', env['type']
      assert_equal 'dev', env['default']

      v = b['options'].find { |o| o['name'] == 'verbose' }
      assert_equal 'boolean', v['type']
      assert_includes v['aliases'], '-v'
      refute v.key?('negation')
      assert_equal '--verbose', v['switch']
    end
  end

  def test_sibling_namespace_grouping
    with_hammerfile(HF_SIBLING) do
      s = spec
      assert_equal ['foo', 'foo:bar'], s['commands']['foo'].keys  # sorted [depth, name]
      refute s['commands'].key?('__root')
    end
  end

  def test_excludes_hidden_and_builtins
    with_hammerfile(HF) do
      s = spec
      refute s['commands']['__root'].key?('default')   # builtin, hidden
      refute s['commands']['__root'].key?('env')       # user task, no desc
      refute s['commands'].key?('h')                   # h: pruned by default
    end
  end

  def test_all_flag_includes_builtins
    with_hammerfile(HF) do
      assert spec(['h:json', '--all'])['commands'].key?('h')
    end
  end

  def test_compact_is_single_line
    with_hammerfile(HF) do
      out, = capture { Hammer.cli(['h:json', '--compact']) }
      assert_equal 1, out.strip.lines.size
      assert JSON.parse(out)   # still valid
    end
  end
end

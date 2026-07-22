require_relative 'test_helper'
require 'tempfile'

class InputTest < Minitest::Test
  include CaptureIO

  def setup
    @stdin_was = $stdin
  end

  def teardown
    $stdin = @stdin_was
  end

  def with_stdin(text, tty: false)
    io = StringIO.new(text)
    def io.tty? = false unless tty
    if tty
      def io.tty? = true
    end
    $stdin = io
    yield
  ensure
    $stdin = @stdin_was
  end

  def test_read_stdin_nil_on_tty
    with_stdin('{"a":1}', tty: true) do
      assert_nil Hammer::Input.read_stdin
    end
  end

  def test_read_stdin_pipe
    with_stdin('{"a":1}') do
      assert_equal '{"a":1}', Hammer::Input.read_stdin
    end
  end

  def test_read_stdin_empty_is_nil
    with_stdin('') do
      assert_nil Hammer::Input.read_stdin
    end
  end

  def test_attach_stdin_idempotent
    with_stdin('hello') do
      opts = {}
      Hammer::Input.attach_stdin!(opts)
      assert_equal 'hello', opts[:stdin]
      opts[:stdin] = 'kept'
      Hammer::Input.attach_stdin!(opts)
      assert_equal 'kept', opts[:stdin]
    end
  end

  def test_prepare_json_from_inline_string
    opts = { json: '{"name":"Ship"}' }
    Hammer::Input.prepare_json!(opts)
    assert_equal({ name: 'Ship' }, opts[:json])
  end

  def test_prepare_json_from_at_file
    Tempfile.create(['body', '.json']) do |f|
      f.write('{"x":1}')
      f.flush
      opts = { json: "@#{f.path}" }
      Hammer::Input.prepare_json!(opts)
      assert_equal({ x: 1 }, opts[:json])
    end
  end

  def test_prepare_json_from_stdin_when_unset
    with_stdin('{"board_ref":"abc"}') do
      opts = {}
      Hammer::Input.attach_stdin!(opts)
      Hammer::Input.prepare_json!(opts)
      assert_equal({ board_ref: 'abc' }, opts[:json])
    end
  end

  def test_prepare_json_dash_uses_stdin
    with_stdin('{"y":2}') do
      opts = { json: '-' }
      Hammer::Input.prepare_json!(opts)
      assert_equal({ y: 2 }, opts[:json])
    end
  end

  def test_prepare_json_skips_non_json_stdin
    with_stdin('not json at all') do
      opts = {}
      Hammer::Input.attach_stdin!(opts)
      Hammer::Input.prepare_json!(opts)
      assert_nil opts[:json]
    end
  end

  def test_prepare_json_leaves_boolean_alone
    with_stdin('{"a":1}') do
      opts = { json: true }
      Hammer::Input.attach_stdin!(opts)
      Hammer::Input.prepare_json!(opts)
      assert_equal true, opts[:json]
    end
  end

  def test_prepare_json_invalid_raises
    opts = { json: '{bad' }
    assert_raises(Hammer::Parser::Error) { Hammer::Input.prepare_json!(opts) }
  end

  def test_type_json_option_cast_inline
    o = Hammer::Option.new(:json, type: :json)
    assert_equal({ a: 1 }, o.cast('{"a":1}'))
  end

  def test_type_json_skips_positional_fill
    o = Hammer::Option.new(:json, type: :json)
    assert o.skip_positional_fill?
    ref = Hammer::Option.new(:ref, req: true)
    pos, opts = Hammer::Parser.new([ref, o]).parse(%w[ABC])
    assert_equal 'ABC', opts[:ref]
    refute opts.key?(:json)
    assert_equal [], pos
  end

  def test_run_command_attaches_stdin
    klass = Class.new(Hammer) do
      task :echo do
        proc do |opts|
          say "stdin=#{opts[:stdin].inspect}"
        end
      end
    end
    with_stdin('piped') do
      out, = capture { klass.start(['echo']) }
      assert_includes out, 'stdin="piped"'
    end
  end

  def test_before_prepare_json_from_pipe
    klass = Class.new(Hammer) do
      global_opt :json, type: :json
      before { |o| Hammer.prepare_json!(o) }
      task :show do
        proc do |opts|
          say "name=#{opts[:json] && opts[:json][:name]}"
        end
      end
    end
    with_stdin('{"name":"Ada"}') do
      out, = capture { klass.start(['show']) }
      assert_includes out, 'name=Ada'
    end
  end

  def test_global_opt_json_flag
    klass = Class.new(Hammer) do
      global_opt :json, type: :json
      before { |o| Hammer.prepare_json!(o) }
      task :show do
        proc do |opts|
          say "n=#{opts.dig(:json, :n)}"
        end
      end
    end
    out, = capture { klass.start(['show', '--json', '{"n":9}']) }
    assert_includes out, 'n=9'
  end

  def test_other_params_still_work_with_json_pipe
    klass = Class.new(Hammer) do
      global_opt :json, type: :json
      before { |o| Hammer.prepare_json!(o) }
      task :update do
        opt :ref, req: true
        opt :force, type: :boolean, default: false
        proc do |opts|
          say "ref=#{opts[:ref]} force=#{opts[:force]} name=#{opts.dig(:json, :name)}"
        end
      end
    end
    with_stdin('{"name":"X"}') do
      out, = capture { klass.start(%w[update ABC --force]) }
      assert_includes out, 'ref=ABC'
      assert_includes out, 'force=true'
      assert_includes out, 'name=X'
    end
  end
end

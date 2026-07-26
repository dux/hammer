require_relative 'test_helper'

class OptionTest < Minitest::Test
  def test_defaults
    o = Hammer::Option.new(:env)
    assert_equal :env,     o.name
    assert_equal :string,  o.type
    assert_equal '--env',  o.switch
    refute o.respond_to?(:negation)
    refute o.boolean?
    refute o.required
    assert_empty o.aliases
  end

  def test_underscore_to_dash_in_switch
    assert_equal '--dry-run', Hammer::Option.new(:dry_run).switch
  end

  def test_boolean_flag
    o = Hammer::Option.new(:verbose, type: :boolean)
    assert o.boolean?
  end

  def test_cast_string
    assert_equal 'foo', Hammer::Option.new(:x).cast('foo')
  end

  def test_cast_integer
    assert_equal 7, Hammer::Option.new(:x, type: :integer).cast('7')
  end

  def test_cast_float
    assert_in_delta 0.5, Hammer::Option.new(:x, type: :float).cast('0.5')
  end

  def test_cast_array
    assert_equal %w[a b c], Hammer::Option.new(:x, type: :array).cast('a,b,c')
  end

  def test_cast_array_passthrough
    assert_equal %w[a b], Hammer::Option.new(:x, type: :array).cast(%w[a b])
  end

  def test_usage_with_desc_and_alias
    o = Hammer::Option.new(:verbose, type: :boolean, alias: :v, desc: 'be loud')
    assert_includes o.usage, '-v'
    assert_includes o.usage, '--verbose'
    assert_includes o.usage, 'be loud'
  end

  def test_single_letter_symbol_alias_becomes_short_flag
    o = Hammer::Option.new(:pretend, alias: :p)
    assert_equal ['-p'], o.aliases
  end

  def test_multi_letter_symbol_alias_becomes_long_flag
    o = Hammer::Option.new(:rollback, alias: :back)
    assert_equal ['--back'], o.aliases
  end

  def test_array_of_symbol_aliases
    o = Hammer::Option.new(:verbose, alias: [:v, :V, :loud])
    assert_equal ['-v', '-V', '--loud'], o.aliases
  end

  def test_string_alias_starting_with_dash_passes_through
    o = Hammer::Option.new(:env, alias: '-E')
    assert_equal ['-E'], o.aliases
  end

  def test_underscore_in_symbol_alias_becomes_dash
    o = Hammer::Option.new(:dry_run, alias: :dry_run)
    assert_equal ['--dry-run'], o.aliases
  end

  def test_unknown_opt_param_raises
    err = assert_raises(Hammer::Error) do
      Hammer::Option.new(:env, alaisi: :e)
    end
    assert_includes err.message, 'unknown opt parameter'
    assert_includes err.message, 'alaisi'
  end

  def test_req_true_sets_required
    o = Hammer::Option.new(:url, req: true)
    assert o.required
  end

  def test_placeholder_in_usage
    o = Hammer::Option.new(:log, type: :string, placeholder: 't/f', desc: 'logging level')
    assert_includes o.usage, '--log t/f'
    assert_includes o.usage, 'logging level'
  end

  def test_custom_placeholder_shows_instead_of_uppercased_name
    o = Hammer::Option.new(:log, placeholder: 'LEVEL')
    assert_includes o.usage, '--log LEVEL'
    refute_includes o.usage, 'LOG'
  end

  def test_options_take_positionals_by_default
    refute Hammer::Option.new(:env).skip_positional_fill?
    refute Hammer::Option.new(:count, type: :integer, positional: true).skip_positional_fill?
  end

  def test_positional_false_is_flag_only
    assert Hammer::Option.new(:lines, type: :integer, positional: false).skip_positional_fill?
  end
end

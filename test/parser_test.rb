require_relative 'test_helper'

class ParserTest < Minitest::Test
  def parse(opts, argv)
    Hammer::Parser.new(opts).parse(argv)
  end

  def test_empty_argv_empty_options
    pos, opts = parse([], [])
    assert_equal [], pos
    assert_equal({}, opts)
  end

  def test_collects_positional
    pos, opts = parse([], %w[a b c])
    assert_equal %w[a b c], pos
    assert_equal({}, opts)
  end

  def test_string_option_with_equals
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[--env=prod])
    assert_equal [], pos
    assert_equal 'prod', opts[:env]
  end

  def test_string_option_with_space
    o = Hammer::Option.new(:env, type: :string)
    _, opts = parse([o], %w[--env prod])
    assert_equal 'prod', opts[:env]
  end

  def test_boolean_via_long_flag
    o = Hammer::Option.new(:verbose, type: :boolean)
    _, opts = parse([o], %w[--verbose])
    assert_equal true, opts[:verbose]
  end

  def test_boolean_presence_is_true_regardless_of_name
    o = Hammer::Option.new(:no_reset, type: :boolean)
    _, opts = parse([o], %w[--no-reset])
    assert_equal true, opts[:no_reset]
  end

  def test_unknown_no_prefix_is_not_auto_negation
    o = Hammer::Option.new(:cache, type: :boolean, default: true)
    assert_raises(Hammer::Parser::Error) { parse([o], %w[--no-cache]) }
  end

  def test_boolean_default_when_omitted
    o = Hammer::Option.new(:cache, type: :boolean, default: true)
    _, opts = parse([o], [])
    assert_equal true, opts[:cache]
  end

  def test_boolean_via_short_alias
    o = Hammer::Option.new(:verbose, type: :boolean, alias: :v)
    _, opts = parse([o], %w[-v])
    assert_equal true, opts[:verbose]
  end

  def test_boolean_equals_false_still_casts
    o = Hammer::Option.new(:verbose, type: :boolean)
    _, opts = parse([o], %w[--verbose=false])
    assert_equal false, opts[:verbose]
  end

  def test_default_when_omitted
    o = Hammer::Option.new(:env, type: :string, default: 'dev')
    _, opts = parse([o], [])
    assert_equal 'dev', opts[:env]
  end

  def test_integer_casting
    o = Hammer::Option.new(:port, type: :integer)
    _, opts = parse([o], %w[--port 8080])
    assert_equal 8080, opts[:port]
  end

  def test_array_casting
    o = Hammer::Option.new(:tags, type: :array)
    _, opts = parse([o], %w[--tags a,b,c])
    assert_equal %w[a b c], opts[:tags]
  end

  def test_double_dash_stops_parsing
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[--env prod -- --not-a-flag x])
    assert_equal %w[--not-a-flag x], pos
    assert_equal 'prod', opts[:env]
  end

  def test_mixed_positional_and_flags
    o = Hammer::Option.new(:env, type: :string)
    pos, opts = parse([o], %w[deploy https://x.com --env=prod])
    assert_equal %w[deploy https://x.com], pos
    assert_equal 'prod', opts[:env]
  end

  def test_unknown_option_raises
    assert_raises(Hammer::Parser::Error) { parse([], %w[--nope]) }
    assert_raises(Hammer::Parser::Error) { parse([], %w[-x]) }
  end

  def test_missing_value_raises
    o = Hammer::Option.new(:env, type: :string)
    assert_raises(Hammer::Parser::Error) { parse([o], %w[--env]) }
  end

  def test_required_missing_raises
    o = Hammer::Option.new(:env, type: :string, req: true)
    assert_raises(Hammer::Parser::Error) { parse([o], []) }
  end

  def test_positional_fills_opts_in_declaration_order
    url = Hammer::Option.new(:url)
    env = Hammer::Option.new(:env)
    pos, opts = parse([url, env], %w[https://x.com prod])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    assert_equal 'prod', opts[:env]
  end

  # Regression: a handler reading its subject from opts[:args] silently loses
  # it to whichever scalar opt is declared first. Both `llm usage` and
  # `llm memory write` were bitten (period landed in :provider, the memory
  # name in :description); the fix is to declare the subject opt first and
  # read it by name.
  def test_bare_positional_is_claimed_by_first_scalar_opt_not_args
    period   = Hammer::Option.new(:period)
    provider = Hammer::Option.new(:provider)

    pos, opts = parse([period, provider], %w[month])
    assert_equal [], pos, 'positional is consumed by opt fill, never reaches opts[:args]'
    assert_equal 'month', opts[:period]
    assert_nil opts[:provider]

    # Declared the other way round, the same argv means something else.
    pos, opts = parse([provider, period], %w[month])
    assert_equal [], pos
    assert_equal 'month', opts[:provider]
  end

  # An explicit flag takes its opt out of the fill pool, so the positional
  # skips to the next un-set one -- why `memory write foo --type=user` put
  # "foo" in :description before :name was declared ahead of it.
  def test_flagged_opt_is_skipped_when_filling_positionals
    name        = Hammer::Option.new(:name)
    type        = Hammer::Option.new(:type)
    description = Hammer::Option.new(:description)

    _pos, opts = parse([type, description], %w[foo --type=user])
    assert_equal 'user', opts[:type]
    assert_equal 'foo', opts[:description], 'documents the bug: name lands in :description'

    _pos, opts = parse([name, type, description], %w[foo --type=user])
    assert_equal 'foo', opts[:name]
    assert_nil opts[:description]
  end

  def test_positional_overflow_goes_to_args
    url = Hammer::Option.new(:url)
    pos, opts = parse([url], %w[https://x.com extra1 extra2])
    assert_equal %w[extra1 extra2], pos
    assert_equal 'https://x.com', opts[:url]
  end

  def test_array_type_consumes_all_positionals
    tags = Hammer::Option.new(:tags, type: :array)
    pos, opts = parse([tags], %w[a b c])
    assert_equal [], pos
    assert_equal %w[a b c], opts[:tags]
  end

  def test_array_type_after_other_opts_consumes_remaining
    url = Hammer::Option.new(:url)
    tags = Hammer::Option.new(:tags, type: :array)
    pos, opts = parse([url, tags], %w[https://x.com a b c])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    assert_equal %w[a b c], opts[:tags]
  end

  def test_positional_skips_booleans
    verbose = Hammer::Option.new(:verbose, type: :boolean)
    url     = Hammer::Option.new(:url)
    pos, opts = parse([verbose, url], %w[https://x.com])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    refute opts.key?(:verbose)
  end

  # A command that forwards its positionals to another program cannot let an
  # opt claim the first one - see `llm wrap --lines 3 -- claude --resume`.
  def test_positional_false_leaves_positionals_alone
    lines = Hammer::Option.new(:lines, type: :integer, default: 2, positional: false)

    pos, opts = parse([lines], %w[claude])
    assert_equal %w[claude], pos
    assert_equal 2, opts[:lines]

    pos, opts = parse([lines], %w[--lines 5 -- claude --resume])
    assert_equal %w[claude --resume], pos
    assert_equal 5, opts[:lines]
  end

  def test_flag_value_wins_over_positional
    url = Hammer::Option.new(:url)
    env = Hammer::Option.new(:env)
    pos, opts = parse([url, env], %w[--env prod https://x.com])
    assert_equal [], pos
    assert_equal 'https://x.com', opts[:url]
    assert_equal 'prod', opts[:env]
  end

  def test_positional_is_cast_to_opt_type
    port = Hammer::Option.new(:port, type: :integer)
    _, opts = parse([port], %w[8080])
    assert_equal 8080, opts[:port]
  end

  def test_positional_satisfies_required
    url = Hammer::Option.new(:url, req: true)
    _, opts = parse([url], %w[https://x.com])
    assert_equal 'https://x.com', opts[:url]
  end
end

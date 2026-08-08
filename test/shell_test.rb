require_relative 'test_helper'

class ShellTest < Minitest::Test
  include CaptureIO

  def setup
    Hammer::Shell.color!(false)
  end

  def test_say_prints_with_newline
    out, = capture { Hammer::Shell.say('hi') }
    assert_equal "hi\n", out
  end

  def test_error_raises_hammer_error
    err = assert_raises(Hammer::Error) { Hammer::Shell.error('boom') }
    assert_equal 'boom', err.message
  end

  def test_print_error_writes_to_stderr_without_exiting
    _, err = capture { Hammer::Shell.print_error('boom') }
    assert_includes err, 'boom'
    assert_includes err, '[error]'
  end

  def test_color_off_returns_plain
    assert_equal 'x', Hammer::Shell.paint('x', :red)
  end

  def test_color_on_wraps_ansi
    Hammer::Shell.color!(true)
    painted = Hammer::Shell.paint('x', :red)
    assert_includes painted, "\e[31m"
    assert_includes painted, "\e[0m"
  ensure
    Hammer::Shell.color!(false)
  end

  def test_ask_returns_default_on_blank_input
    $stdin = StringIO.new("\n")
    out, = capture { @result = Hammer::Shell.ask('name', default: 'world') }
    assert_equal 'world', @result
    assert_includes out, 'name'
  ensure
    $stdin = STDIN
  end

  def test_ask_returns_input
    $stdin = StringIO.new("dino\n")
    capture { @result = Hammer::Shell.ask('name') }
    assert_equal 'dino', @result
  ensure
    $stdin = STDIN
  end

  def test_yes_true_on_y
    $stdin = StringIO.new("y\n")
    capture { @result = Hammer::Shell.yes?('go?') }
    assert_equal true, @result
  ensure
    $stdin = STDIN
  end

  def test_yes_false_on_blank
    $stdin = StringIO.new("\n")
    capture { @result = Hammer::Shell.yes?('go?') }
    assert_equal false, @result
  ensure
    $stdin = STDIN
  end

  def test_sh_runs_command_and_echoes
    out, = capture { Hammer::Shell.sh('true') }
    assert_includes out, '$ true'
  end

  def test_sh_raises_on_nonzero_exit
    err = assert_raises(Hammer::Error) do
      capture { Hammer::Shell.sh('false') }
    end
    assert_includes err.message, 'command failed: false'
  end

  def test_paint_raises_on_unknown_color
    err = assert_raises(Hammer::Error) { Hammer::Shell.paint('x', :magneta) }
    assert_includes err.message, 'unknown color :magneta'
    assert_includes err.message, 'cyan'
  end

  def test_string_color_paints
    Hammer::Shell.color!(true)
    assert_includes 'hi'.color(:cyan), "\e[36m"
  ensure
    Hammer::Shell.color!(false)
  end

  def test_string_color_raises_on_unknown
    err = assert_raises(Hammer::Error) { 'x'.color(:nope) }
    assert_includes err.message, 'unknown color :nope'
  end

  def test_say_proxy_prints_with_color
    Hammer::Shell.color!(true)
    out, = capture { Hammer::Shell.say.cyan('hi') }
    assert_includes out, "\e[36m"
    assert_includes out, 'hi'
  ensure
    Hammer::Shell.color!(false)
  end

  def test_say_proxy_raises_on_unknown_color
    err = assert_raises(Hammer::Error) { Hammer::Shell.say.nope('x') }
    assert_includes err.message, 'unknown color :nope'
  end

  def test_say_empty_string_prints_blank_line
    out, = capture { Hammer::Shell.say('') }
    assert_equal "\n", out
  end

  def test_choose_returns_selected_index_via_numbered_fallback
    $stdin = StringIO.new("2\n")
    out, = capture { @idx = Hammer::Shell.choose('Pick', %w[a b c]) }
    assert_equal 1, @idx
    assert_includes out, '1) a'
    assert_includes out, '2) b'
    assert_includes out, 'select [1-3]:'
  ensure
    $stdin = STDIN
  end

  def test_choose_returns_nil_on_out_of_range
    $stdin = StringIO.new("99\n")
    capture { @idx = Hammer::Shell.choose('Pick', %w[a b c]) }
    assert_nil @idx
  ensure
    $stdin = STDIN
  end

  def test_choose_returns_nil_on_blank_input
    $stdin = StringIO.new("\n")
    capture { @idx = Hammer::Shell.choose('Pick', %w[a b c]) }
    assert_nil @idx
  ensure
    $stdin = STDIN
  end

  def test_choose_returns_nil_on_eof
    $stdin = StringIO.new('')
    capture { @idx = Hammer::Shell.choose('Pick', %w[a b c]) }
    assert_nil @idx
  ensure
    $stdin = STDIN
  end

  def test_choose_raises_on_empty_items
    err = assert_raises(Hammer::Error) do
      capture { Hammer::Shell.choose('Pick', []) }
    end
    assert_includes err.message, 'at least one item'
  end

  # Skipped rows are furniture: on screen, never landed on. The returned index
  # still counts them, so the caller can index straight back into what it passed.
  def test_choose_shows_skipped_rows_but_does_not_number_them
    $stdin = StringIO.new("2\n")
    items  = ['-- fast --', 'dev', '-- slow --', 'prod']
    out, = capture do
      @idx = Hammer::Shell.choose('Pick', items, skip: ->(i) { i.start_with?('--') })
    end

    assert_equal 3, @idx, 'the index addresses the full list, dividers included'
    assert_equal 'prod', items[@idx]
    assert_includes out, '1) dev'
    assert_includes out, '2) prod'
    assert_includes out, '-- fast --', 'a divider is still drawn'
    refute_includes out, '1) -- fast --'
    assert_includes out, 'select [1-2]:', 'only the selectable rows are counted'
  ensure
    $stdin = STDIN
  end

  def test_choose_raises_when_every_row_is_skipped
    err = assert_raises(Hammer::Error) do
      capture { Hammer::Shell.choose('Pick', %w[--- ===], skip: ->(_) { true }) }
    end
    assert_includes err.message, 'at least one selectable item'
  end

  def test_choose_without_skip_is_unchanged
    $stdin = StringIO.new("3\n")
    capture { @idx = Hammer::Shell.choose('Pick', %w[a b c]) }
    assert_equal 2, @idx
  ensure
    $stdin = STDIN
  end
end

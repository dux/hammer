require_relative 'test_helper'
require 'pty'
require 'io/console'

# End-to-end runs of `llm wrap` inside a synthetic terminal: a real pty, a real
# child process, and assertions on the escape sequences the wrapper writes back.
#
# Opt-in. These spawn processes and sleep for timing, so the whole file takes
# roughly a minute and a half - the rest of the suite runs in under a second:
#
#   WRAP_PTY_TESTS=1 hammer test
#
# The parser itself is covered fast and unconditionally in test/wrap_test.rb;
# what is unique here is the terminal geometry, the paint envelope, resize,
# alt-screen, signals and exit status.
class WrapPtyTest < Minitest::Test
  ROWS = 24
  COLS = 80
  LLM  = File.expand_path('~/bin/llm')

  # Keys as a terminal reports them under each protocol.
  KITTY = ->(s) { s.each_char.map { |c| "\e[#{c.ord}u" }.join }
  XTERM = ->(s) { s.each_char.map { |c| "\e[27;1;#{c.ord}~" }.join }

  def setup
    skip 'set WRAP_PTY_TESTS=1 to run the pty suite (~90s)' unless ENV['WRAP_PTY_TESTS']
    skip "no #{LLM} - the wrap recipe is not on this machine" unless File.exist?(LLM)
  end

  # Run `llm wrap <argv>` on a ROWSxCOLS pty, feed `keys` with pauses so the
  # wrapper's select loop sees them as separate keystrokes, return what the
  # wrapper wrote plus the child's exit status.
  def wrap(*argv, keys: [], settle: 0.35)
    out, inp, pid = PTY.spawn({ 'HAMMER_QUIET' => '1' }, LLM, 'wrap', *argv)
    out.winsize = [ROWS, COLS]
    buf = +''
    reader = Thread.new do
      loop { buf << out.readpartial(4096) }
    rescue StandardError
      nil
    end

    sleep settle
    keys.each { |k| inp.write(k); sleep 0.12 }
    sleep settle

    Process.kill('TERM', pid) rescue nil
    reader.join(1)
    _, status = Process.waitpid2(pid) rescue [nil, nil]
    [buf, status]
  ensure
    out&.close rescue nil
    inp&.close rescue nil
  end

  # Spawn without driving it, for the tests that need the pty handle itself.
  def spawn_wrap(*argv, rows: ROWS, cols: COLS, env: {})
    out, inp, pid = PTY.spawn({ 'HAMMER_QUIET' => '1' }.merge(env), LLM, 'wrap', *argv)
    out.winsize = [rows, cols]
    buf = +''
    Thread.new do
      loop { buf << out.readpartial(4096) }
    rescue StandardError
      nil
    end
    [out, inp, pid, -> { buf.dup }]
  end

  # The bar from the last complete paint, top to bottom: [rule, ...prompts].
  # A paint is the whole ESC7 ESC[r ... ESC[1;<child_rows>r ESC8 envelope, so
  # this asserts that shape too - and it deliberately ignores the teardown,
  # which addresses the first bar row last in order to erase it.
  def bar_rows(raw, keep: 3)
    child  = ROWS - (keep + 1)
    paints = raw.dup.force_encoding('UTF-8').scrub('')
                .scan(/\e7\e\[r(.*?)\e\[1;#{child}r\e8/m)
    return [] if paints.empty?

    last = paints.last[0]
    (1..(keep + 1)).map do |i|
      last[/\e\[#{child + i};1H\e\[K(.*?)(?=\e\[\d+;1H|\z)/m, 1]
        .to_s.gsub(/\e\[[\d;?]*[a-zA-Z]/, '').strip
    end
  end

  # Child output with every escape sequence removed. Strips ESC 7 / ESC 8 too:
  # DECRC ends in a literal "8" that would otherwise glue onto a number.
  def visible(raw)
    raw.gsub(/\e[78]/, '').gsub(/\e\[[\d;?]*[a-zA-Z]/, '')
  end

  def size_seen_by_child(raw)
    visible(raw)[/(\d+ \d+)/, 1]
  end

  # -- geometry ------------------------------------------------------------

  def test_child_gets_a_terminal_shorter_by_the_bar
    raw, = wrap('--', 'bash', '-c', 'stty size; sleep 5')
    assert_equal "#{ROWS - 4} #{COLS}", size_seen_by_child(raw), '3 prompts + the rule'
  end

  def test_scroll_region_is_set_and_torn_down
    raw, = wrap('--', 'bash', '-c', 'sleep 0.5')
    assert_includes raw, "\e[1;#{ROWS - 4}r",     'DECSTBM set to the child area'
    assert_includes raw, "\e[r",                  'region reset on exit'
    assert_includes raw, "\e[#{ROWS - 3};1H\e[J", 'bar erased on exit'
    assert_includes raw, "\e[?25h",               'cursor restored on exit'
  end

  def test_lines_option_changes_the_bar_height
    raw, = wrap('--lines', '4', '--', 'bash', '-c', 'stty size; sleep 5')
    assert_equal "#{ROWS - 5} #{COLS}", size_seen_by_child(raw)
  end

  # -- layout --------------------------------------------------------------

  def test_rule_on_top_and_newest_on_the_last_line
    raw, = wrap('--', 'cat', keys: ["hello world\r", "second prompt\r"])
    rows = bar_rows(raw)
    assert_equal COLS, rows[0].length
    assert_includes rows[0], ' prompt history '
    assert_equal '',                 rows[1]
    assert_equal '❯ hello world',    rows[2]
    assert_equal '❯ second prompt',  rows[3]
  end

  def test_three_kept_by_default_and_the_fourth_drops_off
    raw, = wrap('--', 'cat', keys: ["one\r", "two\r", "three\r", "four\r"])
    assert_equal ['❯ two', '❯ three', '❯ four'], bar_rows(raw)[1..]
  end

  def test_placeholder_before_anything_is_typed
    raw, = wrap('--', 'cat')
    assert_equal '(nothing typed yet)', bar_rows(raw)[3]
    assert_equal ['', ''],              bar_rows(raw)[1..2]
  end

  def test_lines_option_pins_that_many
    raw, = wrap('--lines', '4', '--', 'cat', keys: %W[a\r b\r c\r d\r e\r])
    assert_equal ['❯ b', '❯ c', '❯ d', '❯ e'], bar_rows(raw, keep: 4)[1..]

    raw, = wrap('--lines', '1', '--', 'cat', keys: ["only\r"])
    assert_equal ['❯ only'], bar_rows(raw, keep: 1)[1..]
  end

  # `positional: false` on the opt - without it the parser hands "cat" to
  # --lines and dies casting it to an integer.
  def test_lines_option_does_not_swallow_the_command_name
    raw, = wrap('cat', keys: ["bare invocation\r"])
    assert_equal '❯ bare invocation', bar_rows(raw).last
  end

  # -- input ---------------------------------------------------------------

  def test_keys_reported_as_escape_sequences_still_pin
    raw, = wrap('--', 'cat', keys: [KITTY['test 1 - dont do anything'] + "\e[13u"])
    assert_equal '❯ test 1 - dont do anything', bar_rows(raw).last

    raw, = wrap('--', 'cat', keys: [XTERM['test 2 - dont do anything'] + "\e[27;1;13~"])
    assert_equal '❯ test 2 - dont do anything', bar_rows(raw).last
  end

  def test_multi_line_prompts_are_flattened_onto_one_row
    raw, = wrap('--', 'cat', keys: ["first line\e\rsecond line\r"])
    assert_equal '❯ first line\ second line', bar_rows(raw).last

    raw, = wrap('--', 'cat', keys: ["\e[200~one\ntwo\nthree\e[201~\r"])
    assert_equal ['', '', '❯ one\ two\ three'], bar_rows(raw)[1..]
  end

  def test_keystrokes_still_reach_the_child
    raw, = wrap('--', 'cat', keys: ["echoed\r"])
    assert_includes raw, 'echoed'
  end

  # Echo off while still canonical is a password prompt; a raw-mode TUI has
  # canonical off too and must keep being captured.
  def test_password_prompts_are_not_pinned
    script = 'require "io/console"; $stdout.sync = true; print "Password: "; ' \
             '$stdin.noecho { $stdin.gets }; puts "\nok"; sleep 3'
    raw, = wrap('--', 'ruby', '-e', script, keys: ["hunter2\r", "visible\r"])
    refute_includes raw, 'hunter2'
    assert_equal '❯ visible', bar_rows(raw).last
  end

  # -- process behaviour ---------------------------------------------------

  def test_exit_status_is_propagated
    _, status = wrap('--', 'bash', '-c', 'exit 7', settle: 0.4)
    assert_equal 7, status&.exitstatus
  end

  # Wrapping a program hides it: the child has its own session on our pty, so
  # anything watching the pane sees the wrapper. Herdr reads the foreground
  # argv[0] to decide which agent a pane is running, and a pane that looks like
  # `ruby` has no agent - no working spinner, no blocked marker. So we answer to
  # the child's name, and leave the real command line in a file for clone-tab.
  def test_wrapper_takes_the_childs_name_and_writes_the_handoff
    state = Dir.mktmpdir('llm-wrap-pty')
    out, inp, pid, = spawn_wrap('--', 'sleep', '5', env: { 'XDG_STATE_HOME' => state })
    sleep 0.8

    assert_equal 'sleep', `ps -o args= -p #{pid}`.strip
    handoff = File.join(state, 'llm-wrap', pid.to_s)
    assert_path_exists handoff
    assert_equal %w[llm wrap --lines 3 -- sleep 5], File.read(handoff).split("\n")

    Process.kill('TERM', pid)
    Process.waitpid(pid)
    refute_path_exists handoff, 'the record goes away with the process'
  ensure
    out&.close
    inp&.close
    FileUtils.remove_entry(state) if state
  end

  # stderr is left alone on purpose: hammer's run banner goes there by design,
  # so piped stdout has to be exactly the wrapped command's own output.
  def test_non_tty_is_a_plain_passthrough
    plain = `#{LLM} wrap -- echo hi 2>/dev/null | cat`
    assert_equal 'hi', plain.strip
    refute_includes plain, "\e"
  end

  def test_empty_command_is_refused
    `#{LLM} wrap 2>&1`
    refute_equal 0, $?.exitstatus
  end

  def test_resize_reaches_the_child_and_the_region_follows
    out, inp, pid, read = spawn_wrap('--', 'bash', '-c',
                                     'trap "stty size" WINCH; stty size; while :; do sleep 0.2; done')
    sleep 0.8
    out.winsize = [40, 100]
    sleep 0.8
    raw = read.call
    Process.kill('TERM', pid) rescue nil
    Process.waitpid(pid) rescue nil

    sizes = visible(raw).scan(/(\d+) (\d+)/).map { |r, c| "#{r} #{c}" }
    assert_equal ['20 80', '36 100'], sizes.first(2)
    assert_includes raw, "\e[1;36r",  'region re-asserted at the new height'
    assert_includes raw, "\e[40;1H",  'bar repainted down to the last row'
  ensure
    out&.close rescue nil
    inp&.close rescue nil
  end

  # The alt screen starts blank, so the bar has to be repainted over it.
  def test_alt_screen_app_is_sized_to_the_child_area
    out, inp, pid, read = spawn_wrap('--', 'bash', '-c',
                                     'printf "\033[?1049h"; stty size; sleep 1.2; ' \
                                     'printf "\033[?1049l"; sleep 0.6')
    sleep 0.7
    inp.write("typed while in alt screen\r")
    sleep 1.6
    raw = read.call
    Process.kill('TERM', pid) rescue nil
    Process.waitpid(pid) rescue nil

    assert_equal '20 80', size_seen_by_child(raw)
    assert_includes raw, "\e[?1049h"
    after_alt = raw.split("\e[?1049h").last.scan(/\e7\e\[r(.*?)\e\[1;20r\e8/m)
    assert after_alt.any?, 'bar repainted after entering the alt screen'

    paints = raw.scan(/\e7\e\[r(.*?)\e\[1;20r\e8/m)
    assert_includes paints.last[0], 'typed while in alt screen'
  ensure
    out&.close rescue nil
    inp&.close rescue nil
  end

  # Pull the wrapper's own paints back out of the stream and return the child's
  # output as it stood at each one - so a test can ask what the terminal was in
  # the middle of when the bar was written.
  def paint_seams(raw)
    envelope = /\e7\e\[r.*?\e\[1;\d+r\e8/m
    child    = +''.b
    seams    = []
    pos      = 0

    while (m = envelope.match(raw, pos))
      child << raw.byteslice(pos, m.begin(0) - pos)
      seams << child.dup
      pos = m.end(0)
    end

    seams
  end

  # A pty master hands back at most a kilobyte a read, so one redraw arrives as
  # dozens of pieces split at arbitrary bytes - and the wrapper used to paint
  # the bar into whichever seam it happened to be at when MAX_DEFER ran out.
  # That leaves an escape introducer stranded (the literal "[22m" on screen),
  # half a character (a replacement glyph), or the child's own saved cursor
  # taken out from under it, which is what wrapping Claude Code through an
  # interactive question looked like.
  #
  # Real output streams far too fast for those splits to be reproducible, so the
  # child here stalls in each of the three states for longer than MAX_DEFER,
  # which is what the wrapper sees either way.
  CUT_SCRIPT = <<~'RB'
    $stdout.sync = true
    dash = "─".b
    3.times do |n|
      $stdout.write("\e[#{n + 1};1H\e[22m\e[38;5;")  # stalled inside a CSI
      sleep 0.25
      $stdout.write("245m row #{n} ")
      $stdout.write(dash[0, 2])                      # stalled inside a character
      sleep 0.25
      $stdout.write(dash[2])
      $stdout.write("\e7\e[10;1H saved ")            # stalled holding a DECSC
      sleep 0.25
      $stdout.write("\e8\e[0m")
      sleep 0.25                                     # at rest, as a frame ends
    end
    sleep 1
  RB

  def test_the_bar_is_never_painted_into_the_middle_of_the_childs_output
    out, inp, pid, read = spawn_wrap('--', 'ruby', '-e', CUT_SCRIPT)
    sleep 3.5
    raw = read.call.b
    Process.kill('TERM', pid) rescue nil
    Process.waitpid(pid) rescue nil

    seams = paint_seams(raw)
    assert_operator seams.size, :>=, 3, 'the bar should have been painted while output streamed'

    # An unterminated CSI, or a bare ESC, immediately before a paint.
    open_seq = seams.count { |s| s.match?(/(?:\e\[[\d;?]*|\e)\z/n) }
    assert_equal 0, open_seq, 'a paint landed inside an escape sequence'

    # The child writes nothing but valid UTF-8, so a prefix that does not decode
    # is one a paint cut short.
    split_char = seams.count { |s| !s.dup.force_encoding('UTF-8').valid_encoding? }
    assert_equal 0, split_char, 'a paint landed inside a character'

    # The terminal has one cursor save slot. Painting while the child holds it
    # takes it, and the child's ESC8 then lands its cursor on the bar.
    stolen = seams.count { |s| s.scan(/\e7/n).size != s.scan(/\e8/n).size }
    assert_equal 0, stolen, 'a paint took the cursor the child had saved'
  ensure
    out&.close rescue nil
    inp&.close rescue nil
  end

  # Raw mode leaves ISIG off, so Ctrl-C is a plain 0x03 byte the child's own
  # line discipline turns into SIGINT. The wrapper must not take it.
  def test_ctrl_c_reaches_the_child_not_the_wrapper
    out, inp, pid, read = spawn_wrap('--', 'bash', '-c',
                                     'trap "echo CAUGHT_INT" INT; sleep 3; echo DONE')
    sleep 0.7
    inp.write("\x03")
    sleep 0.7
    raw = read.call
    alive = begin
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    assert_includes visible(raw), 'CAUGHT_INT'
    assert alive, 'the wrapper should survive the child being interrupted'
    Process.kill('TERM', pid) rescue nil
    Process.waitpid(pid) rescue nil
  ensure
    out&.close rescue nil
    inp&.close rescue nil
  end
end

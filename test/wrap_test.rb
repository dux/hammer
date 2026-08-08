require_relative 'test_helper'
require_relative '../recipes/lib/llm/wrap'

# LlmWrap::KeyBuffer rebuilds the line you are typing from the raw byte stream
# on its way to the wrapped program. Everything here is pure logic - no PTY, no
# terminal - because that is where every bug in it has actually been:
#
#   * keys do not arrive as bytes. Claude Code turns on the kitty protocol
#     (CSI > 1 u) and xterm modifyOtherKeys (CSI > 4 ; 2 m), so "t" can arrive
#     as "\e[116u" or "\e[27;1;116~".
#   * the terminal answers the program on stdin. Codex asks for the fg/bg
#     colour and the reply "\e]10;rgb:cdcd/d6d6/f4f4\e\\" used to spill its
#     payload into the prompt.
#
# See test/wrap_pty_test.rb for the end-to-end runs (opt-in, they spawn ptys).
class WrapKeyBufferTest < Minitest::Test
  KB = LlmWrap::KeyBuffer

  # Keys as a terminal reports them under each protocol.
  KITTY = ->(s) { s.each_char.map { |c| "\e[#{c.ord}u" }.join }
  XTERM = ->(s) { s.each_char.map { |c| "\e[27;1;#{c.ord}~" }.join }

  def buffer(keep = 2)
    KB.new(keep)
  end

  def feed(kb, *chunks)
    chunks.each { |c| kb.feed(c.b) }
    kb
  end

  # Bar lines with the colour stripped: [rule, ...prompts], newest last.
  def bar(kb, cols = 60)
    kb.lines(cols).map { |line| line.gsub(/\e\[[\d;]*m/, '') }
  end

  def newest(kb, cols = 60) = bar(kb, cols).last
  def older(kb, cols = 60)  = bar(kb, cols)[-2]
  def rule(kb, cols = 60)   = bar(kb, cols).first

  # Typed with a plain keyboard, submitted with Enter.
  def typed(text, keep = 2)
    newest(feed(buffer(keep), text, "\r"))
  end

  # -- layout --------------------------------------------------------------

  def test_rule_on_top_prompts_below_newest_last
    kb   = feed(buffer, "first\r", "second\r")
    dash = LlmWrap::KeyBuffer::RULE
    assert_equal 3, bar(kb).size
    assert_equal "#{dash * 22} prompt history #{dash * 22}", rule(kb)
    assert_equal '❯ first',  older(kb)
    assert_equal '❯ second', newest(kb)
  end

  def test_rule_fills_the_width_exactly
    [20, 33, 60, 120].each { |cols| assert_equal cols, rule(buffer, cols).length }
    assert_includes rule(buffer, 40), ' prompt history '
  end

  def test_rule_drops_the_label_when_too_narrow
    assert_equal LlmWrap::KeyBuffer::RULE * 10, rule(buffer, 10)
  end

  # A pane watcher finds the wrapped program's own furniture by looking for the
  # last solid box rule on the screen - Herdr hangs its "prompt box is here" and
  # "permission dialog is here" regions off it. The bar is below everything, so
  # a solid rule here becomes the last one and takes those regions with it.
  def test_rule_is_not_a_solid_box_drawing_line
    refute_includes rule(buffer, 40), '─',
                    'a solid U+2500 rule shadows the wrapped program on a watched pane'
  end

  def test_default_keep_is_three
    assert_equal 3, LlmWrap::DEFAULT_KEEP
  end

  def test_oldest_falls_off_the_ring
    kb = feed(buffer, "a\r", "b\r", "c\r")
    assert_equal ['❯ b', '❯ c'], [older(kb), newest(kb)]
  end

  def test_placeholder_sits_on_the_last_line
    assert_equal '(nothing typed yet)', newest(buffer)
    assert_equal '', older(buffer)
  end

  # -- submitting ----------------------------------------------------------

  def test_blank_enter_does_not_submit
    assert_equal '❯ x', newest(feed(buffer, "x\r", "\r", "   \r"))
  end

  def test_repeat_of_the_last_prompt_is_not_pinned_twice
    kb = feed(buffer, "same\r", "same\r")
    assert_equal ['', '❯ same'], [older(kb), newest(kb)]
  end

  def test_feed_reports_only_real_changes
    kb = buffer
    refute kb.feed('abc'.b), 'typing alone is not a change'
    assert kb.feed("\r".b),  'submitting is a change'
  end

  # -- line editing --------------------------------------------------------

  def test_backspace
    assert_equal '❯ hello', newest(feed(buffer, 'helo', "\x7f", "lo\r"))
    assert_equal '❯ ac',    newest(feed(buffer, 'ab', "\b", "c\r"))
  end

  def test_backspace_removes_a_whole_character_not_a_byte
    assert_equal '❯ na', newest(feed(buffer, 'naï', "\x7f", "\r"))
    assert_equal '❯ ok', newest(feed(buffer, 'ok 🎉', "\x7f", "\r"))
  end

  def test_ctrl_u_and_ctrl_c_clear_the_line
    assert_equal '❯ kept', newest(feed(buffer, "junk\x15kept\r"))
    assert_equal '❯ kept', newest(feed(buffer, "junk\x03kept\r"))
  end

  def test_ctrl_w_drops_a_word_leaving_the_separator
    assert_equal '❯ one three', newest(feed(buffer, "one two\x17three\r"))
  end

  def test_tab_is_ignored_because_the_completion_is_inserted_by_the_app
    assert_equal '❯ abcd', typed("ab\tcd")
  end

  # -- reassembly ----------------------------------------------------------

  def test_escape_sequence_split_across_reads
    assert_equal '❯ abcd', newest(feed(buffer, 'ab', "\e", '[', 'A', "cd\r"))
  end

  def test_utf8_character_split_across_reads
    bytes = 'héllo'.b
    assert_equal '❯ héllo', newest(feed(buffer, bytes[0, 2], bytes[2..], "\r"))
  end

  # -- kitty keyboard protocol ---------------------------------------------

  def test_kitty_plain_typing
    assert_equal '❯ test 2', newest(feed(buffer, KITTY['test 2'], "\e[13u"))
  end

  def test_kitty_shift_produces_uppercase
    assert_equal '❯ T', newest(feed(buffer, "\e[116;2u\e[13u"))
  end

  def test_kitty_associated_text_field_wins_over_the_key_code
    assert_equal '❯ T', newest(feed(buffer, "\e[116;2;84u\e[13u"))
  end

  def test_kitty_key_release_ignored_but_repeat_kept
    assert_equal '❯ a',  newest(feed(buffer, "\e[97u\e[98;1:3u\e[13u"))
    assert_equal '❯ ab', newest(feed(buffer, "\e[97u\e[98;1:2u\e[13u"))
  end

  def test_kitty_backspace_and_unicode
    assert_equal '❯ ab', newest(feed(buffer, KITTY['abc'], "\e[127u", "\e[13u"))
    assert_equal '❯ č',  newest(feed(buffer, "\e[269u\e[13u"))
  end

  # Ctrl-V pastes an image in Claude Code and puts no typed text on the wire.
  def test_kitty_ctrl_v_is_not_text
    assert_equal '❯ ab', newest(feed(buffer, KITTY['ab'], "\e[118;5u", "\e[13u"))
  end

  def test_kitty_ctrl_u_and_ctrl_w_still_edit
    assert_equal '❯ kept',      newest(feed(buffer, KITTY['junk'], "\e[117;5u", KITTY['kept'], "\e[13u"))
    assert_equal '❯ one three', newest(feed(buffer, KITTY['one two'], "\e[119;5u", KITTY['three'], "\e[13u"))
  end

  def test_kitty_alt_and_tab_are_not_text
    assert_equal '❯ ab', newest(feed(buffer, KITTY['ab'], "\e[99;3u", "\e[13u"))
    assert_equal '❯ ab', newest(feed(buffer, KITTY['ab'], "\e[9u", "\e[13u"))
  end

  def test_kitty_enter_submits_only_unmodified
    assert_equal '❯ done',  newest(feed(buffer, KITTY['done'], "\e[13u"))
    assert_equal '❯ a\ b',  newest(feed(buffer, 'a', "\e[13;2u", 'b', "\r"))
    assert_equal '❯ a\ b',  newest(feed(buffer, 'a', "\e[13;5u", 'b', "\r"))
  end

  # -- xterm modifyOtherKeys -----------------------------------------------

  def test_xterm_plain_typing
    assert_equal '❯ test 3', newest(feed(buffer, XTERM['test 3'], "\e[27;1;13~"))
  end

  def test_xterm_shifted_code_is_the_literal_character
    assert_equal '❯ T', newest(feed(buffer, "\e[27;2;84~\e[13u"))
  end

  def test_xterm_ctrl_v_is_not_text
    assert_equal '❯ ab', newest(feed(buffer, XTERM['ab'], "\e[27;5;118~", "\e[13u"))
  end

  def test_xterm_shift_enter_continues
    assert_equal '❯ a\ b', newest(feed(buffer, 'a', "\e[27;2;13~", 'b', "\r"))
  end

  # -- the terminal talking back -------------------------------------------
  #
  # Replies to the program's own queries. Their payload is printable text, so
  # mishandling them puts terminal chatter in the prompt.

  OSC_FG = "\e]10;rgb:cdcd/d6d6/f4f4\e\\".freeze
  OSC_BG = "\e]11;rgb:1e1e/1e1e/2e2e\e\\".freeze

  def test_osc_colour_replies_are_not_typing
    assert_equal '❯ test 1 - ignore',
                 newest(feed(buffer, OSC_FG, OSC_BG, 'test 1 - ignore', "\r"))
  end

  def test_osc_terminated_by_bel
    assert_equal '❯ ab', newest(feed(buffer, "\e]11;rgb:1e1e/1e1e/2e2e\a", "ab\r"))
  end

  def test_osc_split_across_reads_and_arriving_mid_word
    assert_equal '❯ ab',   newest(feed(buffer, "\e]10;rgb:cd", "cd/d6d6/f4f4\e\\", "ab\r"))
    assert_equal '❯ test', newest(feed(buffer, 'te', OSC_BG, "st\r"))
  end

  def test_dcs_and_apc_payloads_are_dropped
    assert_equal '❯ ab', newest(feed(buffer, "\eP>|WezTerm 20240203\e\\", "ab\r"))
    assert_equal '❯ ab', newest(feed(buffer, "\e_Gi=1,a=T\e\\", "ab\r"))
  end

  # A lost terminator must not swallow every keystroke from then on, so the
  # sequence is abandoned after 1024 bytes. What followed it in that same run
  # does leak - the guarantee is only that capture recovers.
  def test_unterminated_osc_is_abandoned_not_fatal
    kb = feed(buffer, "\e]10;#{'x' * 1100}", "junk\r")
    assert newest(kb, 200).end_with?('junk')
    assert_equal '❯ after', newest(feed(kb, "after\r"))
  end

  def test_mouse_focus_arrow_and_device_reports_are_not_typing
    assert_equal '❯ ab', newest(feed(buffer, 'ab', "\e[<35;10;20M\e[<35;11;21m", "\r"))
    assert_equal '❯ ab', newest(feed(buffer, 'ab', "\e[I\e[O", "\r"))
    assert_equal '❯ ab', newest(feed(buffer, 'ab', "\e[A\e[D", "\r"))
    assert_equal '❯ ab', newest(feed(buffer, 'ab', "\e[1~\e[3~", "\r"))
    assert_equal '❯ ab', newest(feed(buffer, 'ab', "\e[?1;2c\e[24;80R", "\r"))
    assert_equal '❯ abcd', newest(feed(buffer, 'ab', "\eOA", "cd\r"))
  end

  # The original report: everything but the digit was being eaten.
  def test_a_whole_sentence_survives_every_encoding
    sentence = 'test 1 - dont do anything'
    assert_equal "❯ #{sentence}", newest(feed(buffer, KITTY[sentence], "\e[13u"))
    assert_equal "❯ #{sentence}", newest(feed(buffer, XTERM[sentence], "\e[13u"))
    assert_equal "❯ #{sentence}", typed(sentence)
  end

  # -- multi-line and paste ------------------------------------------------

  def test_paste_is_one_prompt_with_visible_line_breaks
    kb = feed(buffer, "\e[200~one\ntwo\nthree\e[201~\r")
    assert_equal '❯ one\ two\ three', newest(kb)
    assert_equal '', older(kb), 'a pasted block must not split into several prompts'
  end

  def test_paste_then_typing_is_still_one_prompt
    assert_equal '❯ pasted typed', newest(feed(buffer, "\e[200~pasted\e[201~", " typed\r"))
  end

  def test_leading_and_trailing_newlines_are_trimmed
    assert_equal '❯ pasted', newest(feed(buffer, "\e[200~pasted\n\e[201~\r"))
  end

  def test_option_enter_continues_the_line
    assert_equal '❯ line one\ line two', newest(feed(buffer, "line one\e\rline two\r"))
  end

  def test_horizontal_whitespace_is_collapsed
    assert_equal '❯ a b', typed('  a   b  ')
  end

  # -- clipping ------------------------------------------------------------

  def test_long_prompt_is_clipped_to_the_width
    line = newest(feed(buffer, "#{'x' * 200}\r"), 30)
    assert_equal 30, line.length
    assert_equal '…', line[-1]
  end

  def test_wide_characters_count_as_two_cells
    line  = newest(feed(buffer, "#{'漢' * 40}\r"), 20)
    cells = line.sub('❯ ', '').each_char.sum { |c| c == '…' ? 1 : 2 }
    assert_operator cells + 2, :<=, 20
  end

  def test_oversized_input_is_capped
    assert_operator newest(feed(buffer, "#{'y' * 9000}\r"), 100).length, :<=, 100
  end
end

# LlmWrap::OutScan watches the child's output go past and says whether the
# terminal's parser is at rest, which is the only moment the bar may be painted.
#
# A pty master hands back at most a kilobyte a read, so a redraw arrives split
# at arbitrary bytes: every case here is a sequence or a character cut in half
# by that split, which is exactly what a paint used to land in the middle of.
class WrapOutScanTest < Minitest::Test
  def scan(*chunks)
    s = LlmWrap::OutScan.new
    chunks.each { |c| s.feed(c.b) }
    s
  end

  def assert_safe(*chunks)
    assert scan(*chunks).safe?, "expected a resting parser after #{chunks.inspect}"
  end

  def refute_safe(*chunks)
    refute scan(*chunks).safe?, "expected a sequence still open after #{chunks.inspect}"
  end

  def test_plain_text_is_always_safe
    assert_safe 'hello world'
    assert_safe "one\r\ntwo\tthree"
  end

  def test_a_bare_escape_is_not_a_boundary
    refute_safe "\e"
    refute_safe 'text', "\e"
  end

  def test_csi_is_open_until_its_final_byte
    refute_safe "\e["
    refute_safe "\e[38;5;"
    assert_safe "\e[38;5;245m"
    assert_safe "\e[38;5;", '245m'
    assert_safe "\e[?1049h"
  end

  def test_csi_split_across_reads
    refute_safe "\e[1;20"
    assert_safe "\e[1;20", 'r'
  end

  def test_ss3_and_charset_designators_take_one_more_byte
    refute_safe "\eO"
    assert_safe "\eOP"
    refute_safe "\e("
    assert_safe "\e(B"
  end

  def test_two_byte_escapes_end_on_the_second_byte
    assert_safe "\eM"
    assert_safe "\e="
  end

  def test_osc_runs_to_bel_or_st
    refute_safe "\e]0;a title"
    assert_safe "\e]0;a title\a"
    assert_safe "\e]0;a title", "\e\\"
    refute_safe "\e]0;a title", "\e"
  end

  # An OSC payload can hold anything, including bytes that end a CSI - reading
  # it as one would call the middle of a window title a boundary.
  def test_osc_payload_is_not_read_as_a_csi
    refute_safe "\e]10;rgb:cdcd/d6d6/f4f4"
    assert_safe "\e]10;rgb:cdcd/d6d6/f4f4", "\e\\"
  end

  def test_dcs_and_apc_are_string_sequences_too
    refute_safe "\eP1$r"
    assert_safe "\eP1$r0m", "\e\\"
    refute_safe "\e_G"
    assert_safe "\e_G", "\e\\"
  end

  def test_utf8_character_split_across_reads
    bytes = '─'.b
    refute_safe bytes[0]
    refute_safe bytes[0, 2]
    assert_safe bytes
    assert_safe bytes[0, 2], bytes[2]

    emoji = '🙂'.b
    refute_safe emoji[0, 3]
    assert_safe emoji
  end

  # The child's own cursor save. The terminal has one slot, so painting between
  # the two would take it and its ESC8 would land the cursor on our bar - Claude
  # Code wraps every repaint in this pair.
  def test_an_open_decsc_is_not_a_boundary
    refute_safe "\e7"
    refute_safe "\e7", "\e[5;1H", 'some text'
    assert_safe "\e7", "\e[5;1H", 'some text', "\e8"
  end

  def test_an_unmatched_decrc_does_not_go_negative
    assert_safe "\e8"
    assert_safe "\e8\e8\e7\e8"
  end

  def test_reset_forgives_a_stream_we_have_lost
    s = scan("\e]0;never terminated")
    refute_predicate s, :safe?
    s.reset!
    assert_predicate s, :safe?
  end

  def test_runaway_sequences_do_not_block_forever
    assert_safe "\e[#{'1;' * 200}"
    assert_safe "\e]0;#{'x' * 9000}"
  end

  # The fast path skips the byte walk when a chunk cannot start a sequence or a
  # character - it must not lose state that is already open.
  def test_the_plain_text_fast_path_keeps_open_state
    refute_safe "\e[", '38;5;245'
    refute_safe "\e7", 'plain ascii'
    assert_safe "\e[", '38;5;245', 'm'
  end
end

# The wrapper answers to the name of the program it runs, so that anything
# watching the pane can still tell what is in it - which leaves nothing behind
# that says how the pane was started. Handoff is that record, and Herdr's
# clone-tab reads it back to reopen the same wrapper.
class WrapHandoffTest < Minitest::Test
  HO = LlmWrap::Handoff

  def setup
    @state = Dir.mktmpdir('llm-wrap-test')
    @was   = ENV['XDG_STATE_HOME']
    ENV['XDG_STATE_HOME'] = @state
  end

  def teardown
    ENV['XDG_STATE_HOME'] = @was
    FileUtils.remove_entry(@state)
  end

  def test_writes_one_argument_per_line_named_after_our_pid
    HO.write(['llm', 'wrap', '--lines', '3', '--', 'claude'])
    assert_equal Process.pid.to_s, File.basename(HO.path)
    assert_equal %w[llm wrap --lines 3 -- claude], File.read(HO.path).split("\n")
  ensure
    HO.clear
  end

  def test_clear_removes_it_and_is_fine_when_already_gone
    HO.write(%w[llm wrap claude])
    HO.clear
    refute_path_exists HO.path
    HO.clear
  end

  def test_sweep_drops_entries_whose_process_is_gone
    dead = spawn_and_reap
    live = File.join(HO.dir, Process.pid.to_s)
    FileUtils.mkdir_p(HO.dir)
    File.write(File.join(HO.dir, dead.to_s), "llm\nwrap\nclaude")
    File.write(live, "llm\nwrap\nclaude")

    HO.sweep

    refute_path_exists File.join(HO.dir, dead.to_s), 'a stale pid can be reused by anyone'
    assert_path_exists live
  ensure
    HO.clear
  end

  def test_sweep_ignores_files_that_are_not_pids
    FileUtils.mkdir_p(HO.dir)
    junk = File.join(HO.dir, 'README')
    File.write(junk, 'not a pid')
    HO.sweep
    assert_path_exists junk
  end

  private

  # A pid that is certainly free: run something trivial and wait for it.
  def spawn_and_reap
    pid = Process.spawn('true', out: File::NULL, err: File::NULL)
    Process.wait(pid)
    pid
  end
end

# The command list behind a bare `llm wrap`. Plain text on purpose, so the
# tests are mostly about being forgiving with what someone hand-edits into it.
class WrapConfigTest < Minitest::Test
  CF = LlmWrap::Config

  def setup
    @dir = Dir.mktmpdir('llm-wrap-config-test')
    @was = ENV['LLM_WRAP_CONFIG']
    ENV['LLM_WRAP_CONFIG'] = File.join(@dir, 'nested', 'llm-wrap.txt')
  end

  def teardown
    ENV['LLM_WRAP_CONFIG'] = @was
    FileUtils.remove_entry(@dir)
  end

  def write(text)
    FileUtils.mkdir_p(File.dirname(CF.path))
    File.write(CF.path, text)
  end

  def test_seed_creates_the_file_and_its_directory
    assert CF.seed, 'seeding a missing file reports that it wrote one'
    assert_equal CF::DEFAULTS, CF.lines
  end

  def test_seed_overwrites_a_file_that_is_only_whitespace
    write("\n  \n\t\n")
    assert CF.seed
    assert_equal CF::DEFAULTS, CF.lines
  end

  def test_seed_leaves_a_file_that_has_content
    write("bash -l\n")
    refute CF.seed, 'an existing list is never overwritten'
    assert_equal ['bash -l'], CF.lines
  end

  # Commented-out lines are notes, not an empty file - seeding over them would
  # throw away the thing someone parked there.
  def test_seed_leaves_a_file_that_is_only_comments
    write("# claude --resume\n")
    refute CF.seed
    assert_empty CF.lines
  end

  def test_lines_drops_comments_and_strips
    write("claude\n  # a note\n   codex resume   \n")
    assert_equal ['claude', 'codex resume'], CF.lines
  end

  # Dividers stay in the list - they are there to be looked at. What they are
  # not is runnable, and the picker steps over them on that basis.
  def test_dividers_are_kept_but_not_runnable
    write("claude\n----\n====\n***\n  \n7z x archive.7z\n")
    assert_equal ['claude', '----', '====', '***', '', '7z x archive.7z'], CF.lines

    runnable = CF.lines.select { |line| CF.runnable?(line) }
    assert_equal ['claude', '7z x archive.7z'], runnable,
                 'a leading digit is fine - the whole line is searched for a letter'
  end

  def test_lines_strips_after_selecting_so_an_indented_comment_is_still_one
    write("\t# parked\n\t  claude --continue\t\n")
    assert_equal ['claude --continue'], CF.lines
  end

  def test_argv_splits_honouring_quotes
    assert_equal %w[bash -l], CF.argv('bash -l')
    assert_equal ['zsh', '-ic', 'codex --yolo'], CF.argv(%(zsh -ic 'codex --yolo'))
  end

  def test_missing_file_reads_as_empty_rather_than_raising
    assert_empty CF.lines
  end

  # Every seeded line has to survive the same split the picker feeds to
  # PTY.spawn - a typo in DEFAULTS would only show up at launch otherwise.
  def test_defaults_are_all_parseable_commands
    CF.seed
    argvs = CF.lines.map { |line| CF.argv(line) }
    assert_equal CF::DEFAULTS.size, argvs.size
    argvs.each { |argv| assert_operator argv.size, :>=, 2 }
    assert_equal %w[claude codex grok], argvs.map(&:first)
  end
end

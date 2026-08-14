# frozen_string_literal: true

require 'fileutils'
require 'io/console'
require 'pty'
require 'shellwords'

# Run a command in a PTY with the last prompts you typed pinned to the bottom
# rows of the screen, under a "prompt history" rule.
#
# The trick is to lie about the terminal size: the child gets a PTY that is
# a few rows shorter than the real terminal, so it renders inside that and never
# draws over the bar - even a full-screen TUI. A scroll region (DECSTBM) keeps
# normal-buffer scrolling above the bar as well.
#
# A "prompt" is whatever you type between Enters. This is keystroke sniffing,
# so text the program inserts for you (history recall, autocomplete, menu
# picks) never shows up - that is the price of working with any program at all.
#
# A line starting with ! is taken over: it never reaches the child at all, it
# runs in a shell here, and its output is shown in the bar (Bang, Pane). The
# round trip that saves is the point - `!git status` typed at an agent is a
# tool call, a permission check and a model turn for something the shell
# answers in milliseconds, and this way it costs no context either.
#
# Wrapping a program hides it: the child lives on our PTY, in its own session,
# so anything outside looking at the terminal sees this process and not the
# program. Terminals that watch what is running in a pane - Herdr naming a tab,
# or deciding whether an agent is thinking, waiting, or idle - go blind, and the
# fix is to stop hiding rather than to relay anything: we borrow the child's
# name (Session#adopt_child_name) and keep the bar from imitating the child's
# own screen furniture (KeyBuffer::RULE).
module LlmWrap
  # Prompts pinned, oldest first, so the newest sits on the very last line -
  # closest to where you are typing. A labelled rule sits above them, so the
  # bar is one row taller than the number of prompts.
  DEFAULT_KEEP ||= 3
  MAX_KEEP     ||= 20

  # Poll gap used to notice that the child's output has settled, and the
  # longest we let a stale bar sit while output keeps streaming.
  IDLE_TICK ||= 0.02
  MAX_DEFER ||= 0.15
  CHUNK     ||= 65_536

  # A pty master hands back at most a kilobyte per read whatever CHUNK says, so
  # one redraw arrives as dozens of pieces. DRAIN_MAX caps how much of it we
  # take in a single go, so a child that never stops talking cannot starve the
  # keyboard. MAX_BLOCK is how long a paint will wait for a safe moment before
  # giving up and taking one - see Session#paint.
  DRAIN_MAX ||= 262_144
  MAX_BLOCK ||= 1.5

  # The bar grows to show ! output, and this is what it may never take: the
  # child keeps at least this many rows whatever the output was.
  MIN_CHILD ||= 5

  # Introducers of the escape sequences that carry a string payload:
  # OSC ], DCS P, SOS X, PM ^, APC _. They run to BEL or ST rather than to a
  # final byte, so both stream parsers here - KeyBuffer on the way in, OutScan
  # on the way out - have to know them to find the end of one.
  STRING_INTRO ||= [0x5d, 0x50, 0x58, 0x5e, 0x5f].freeze

  # `origin` is how this wrapper was asked for, in the words that would ask for
  # it again - only the caller knows that, since taking the child's name throws
  # our own command line away. It is what Handoff writes down; the child's argv
  # stands in when nobody says.
  def self.run(argv, keep: DEFAULT_KEEP, origin: argv)
    keep = keep.to_i.clamp(1, MAX_KEEP)
    return passthrough(argv) unless $stdin.tty? && $stdout.tty?

    rows, = $stdout.winsize
    # Leave the child a usable screen, or skip the bar entirely.
    return passthrough(argv) if rows.to_i < keep + 4

    Session.new(argv, keep, origin).run
  end

  # No terminal to draw on (piped, scripted, inside another wrapper), so get
  # out of the way completely rather than half-working.
  def self.passthrough(argv)
    exec(*argv)
  rescue Errno::ENOENT
    warn "llm wrap: command not found: #{argv.first}"
    127
  end

  # Reads the child's line discipline through the PTY master. Used only to tell
  # a password prompt (echo off, still canonical) apart from a raw-mode TUI
  # (echo off, canonical off) - see Session#capture?.
  module Termios
    # struct termios: c_iflag, c_oflag, c_cflag, c_lflag, ... - we want c_lflag.
    # Darwin/BSD fields are unsigned long (8b), Linux uses uint32 (4b), and the
    # ICANON bit differs between them.
    GETA, LFLAG_AT, LFLAG_PACK, ICANON, ECHO =
      if RUBY_PLATFORM.match?(/darwin|bsd/)
        [0x4048_7413, 24, 'Q', 0x100, 0x8] # TIOCGETA
      else
        [0x5401, 12, 'L', 0x2, 0x8]        # TCGETS
      end

    # [echo?, canonical?], or nil when the ioctl is not understood here.
    def self.state(io)
      buf = String.new("\0" * 128)
      io.ioctl(GETA, buf)
      lflag = buf.unpack1("@#{LFLAG_AT}#{LFLAG_PACK}")
      [(lflag & ECHO) != 0, (lflag & ICANON) != 0]
    rescue SystemCallError, IOError, ArgumentError
      nil
    end
  end

  # Drawing shared by everything that puts a row in the bar: the prompt history
  # and the ! output pane.
  module Text
    CYAN   = "\e[36m"
    YELLOW = "\e[33m"
    DIM    = "\e[2m"
    GRAY   = "\e[38;5;245m"
    REV    = "\e[7m"
    RESET  = "\e[0m"

    # Dashed, and deliberately not the solid U+2500 "─" it wants to be.
    #
    # A pane watcher works out where a program's own furniture is by looking for
    # the last solid rule on the screen: Herdr hangs its "the prompt box is
    # here" and "the permission dialog is here" regions off it. Our bar is below
    # everything, so a solid rule down here becomes the last one and those
    # regions land on the prompt history instead - detection then sees no prompt
    # and no dialog, and the pane reads as neither idle nor blocked. Any glyph
    # that is not box-drawing keeps the bar out of that reckoning; a dashed rule
    # is also a fair signal that this row is not part of the program above.
    RULE ||= '┄'

    # Roughly the double-width ranges of UEAW - enough to keep CJK and emoji
    # from overflowing the bar without pulling in a character-width gem.
    WIDE ||= [
      0x1100..0x115f, 0x2e80..0x303e, 0x3041..0x33ff, 0x3400..0x4dbf,
      0x4e00..0x9fff, 0xa000..0xa4cf, 0xac00..0xd7a3, 0xf900..0xfaff,
      0xfe30..0xfe6f, 0xff00..0xff60, 0xffe0..0xffe6,
      0x1f300..0x1f64f, 0x1f900..0x1f9ff, 0x20000..0x2fffd
    ].freeze
    ZERO ||= [0xfe00..0xfe0f, 0x200b..0x200f].freeze

    private

    # A full-width rule with the label centred in it, marking off the bar from
    # whatever the wrapped program is drawing above it.
    def rule(cols, label)
      return '' if cols <= 0

      label = " #{label} "
      pad   = cols - width(label)
      return "#{GRAY}#{RULE * cols}#{RESET}" if pad < 2

      left = pad / 2
      "#{GRAY}#{RULE * left}#{label}#{RULE * (pad - left)}#{RESET}"
    end

    def dim(text)
      "#{DIM}#{text}#{RESET}"
    end

    def clip(text, cells)
      return '' if cells <= 0
      return text if width(text) <= cells

      out  = +''
      used = 0
      text.each_char do |ch|
        w = char_width(ch)
        break if used + w > cells - 1

        out << ch
        used += w
      end
      out << '…'
    end

    def width(text)
      text.each_char.sum { |ch| char_width(ch) }
    end

    def char_width(char)
      cp = char.ord
      return 0 if cp == 0x200d || ZERO.any? { |r| r.cover?(cp) }

      WIDE.any? { |r| r.cover?(cp) } ? 2 : 1
    rescue RangeError
      1
    end
  end

  # Taking the child's name costs us our own command line, and that is the only
  # record of how the pane was started - Herdr's clone-tab reads it back off the
  # foreground process to reopen the same wrapper. So leave it in a file named
  # after our pid: whoever can see the process can find the command. One
  # argument per line, and the file goes away when we do.
  module Handoff
    # Read at call time rather than frozen into a constant at load: this is a
    # long-lived process, and the tests need somewhere else to write.
    def self.dir
      state = ENV['XDG_STATE_HOME'].to_s
      state = File.join(Dir.home, '.local/state') if state.empty?
      File.join(state, 'llm-wrap')
    end

    def self.path(pid = Process.pid)
      File.join(dir, pid.to_s)
    end

    def self.write(argv)
      FileUtils.mkdir_p(dir)
      sweep
      File.write(path, argv.join("\n"))
    rescue SystemCallError, IOError
      nil
    end

    def self.clear
      File.unlink(path)
    rescue SystemCallError
      nil
    end

    # A crash leaves its file behind, and pids come round again - a stale entry
    # would hand clone-tab someone else's command line. Drop the ones whose
    # process is gone. Signal 0 only asks; EPERM means it is alive and not ours.
    def self.sweep
      Dir.children(dir).each do |name|
        pid = Integer(name, exception: false) or next

        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          File.unlink(File.join(dir, name))
        rescue SystemCallError
          nil
        end
      end
    rescue SystemCallError, IOError
      nil
    end
  end

  # The commands `llm wrap` offers when asked for no particular one. Plain
  # text, one command per line - nothing to learn, editable with anything.
  #
  # A # comment is dropped, so a command can be parked without being deleted.
  # A line with no letter in it is kept but not runnable: blanks and ---- rules
  # stay visible in the picker to group the list, the cursor just steps over
  # them. No executable name is spelled without a letter, so nothing real is
  # caught by that.
  module Config
    DEFAULTS ||= [
      'claude --dangerously-skip-permissions --continue',
      'codex resume --last --dangerously-bypass-approvals-and-sandbox',
      'grok --always-approve --continue'
    ].freeze

    # A method rather than a constant for the same reason as Handoff.dir: the
    # tests need somewhere else to write.
    def self.path
      ENV['LLM_WRAP_CONFIG'] || File.expand_path('~/.config/hammer/llm-wrap.txt')
    end

    def self.lines
      return [] unless File.file?(path)

      # Decide what to keep first, then tidy what survived - lstrip inside the
      # test so an indented # is still a comment.
      File.readlines(path, chomp: true)
          .reject { |line| line.lstrip.start_with?('#') }
          .map(&:strip)
    rescue SystemCallError, IOError
      []
    end

    # A row the picker shows but will not run. Nothing without a letter in it
    # can name a program, which makes ---- and a blank line free to use as
    # dividers without needing a syntax for them.
    def self.runnable?(line)
      line.match?(/[a-z]/i)
    end

    # Split rather than hand the line over whole: PTY.spawn passes a
    # one-element argv to /bin/sh, and a command out of this file should reach
    # the wrapper the same way `llm wrap claude --foo` already does - as argv,
    # no shell in between.
    def self.argv(line)
      Shellwords.split(line)
    end

    # Writes DEFAULTS when there is nothing there yet - no file, or one that is
    # only whitespace. A file holding just commented-out lines is left alone;
    # those are someone's notes, not an empty file.
    def self.seed
      return false if File.file?(path) && !File.read(path).strip.empty?

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{DEFAULTS.join("\n")}\n")
      true
    end
  end

  class Session
    def initialize(argv, keep, origin = argv)
      @argv     = argv
      @origin   = origin
      @bar_rows = keep + 1     # the prompts, plus the rule above them
      @keys     = KeyBuffer.new(keep)
      @pane     = nil          # the last ! command's output, while one is up
      @out      = OutScan.new
      @winch    = false
      @dirty    = true
      @drawn_at = 0.0
      @blocked  = nil
      @skipped  = nil
      @started  = now
      @trace    = (File.open(ENV['LLM_WRAP_DEBUG'], 'a') if ENV['LLM_WRAP_DEBUG'].to_s != '')
    rescue SystemCallError
      @trace = nil
    end

    def run
      @rows, @cols = $stdout.winsize
      $stdout.sync = true

      @pty_out, @pty_in, @pid = PTY.spawn(*@argv)
      resize_child
      adopt_child_name
      trace('RUN', "#{@argv.inspect} term=#{ENV['TERM'].inspect} #{@rows}x#{@cols} " \
                   "child=#{child_rows}x#{@cols}")
      Signal.trap('WINCH') { @winch = true }

      begin
        enter_screen
        # raw leaves ISIG off, so Ctrl-C reaches the child as a plain 0x03 byte
        # and its own line discipline signals it. We must not trap SIGINT here.
        $stdin.raw { pump }
      ensure
        leave_screen
        Handoff.clear
      end

      reap
    rescue Errno::ENOENT
      warn "llm wrap: command not found: #{@argv.first}"
      127
    end

    private

    # Answer to the child's name, so a pane running `llm wrap claude` reads from
    # the outside as a pane running `claude`.
    #
    # Everything that watches a terminal pane identifies what is in it from the
    # foreground process, and our child is not it: it has its own session on our
    # PTY and is invisible from out there. Herdr in particular matches argv[0]
    # against the agent it knows - see `herdr pane process-info` - and with
    # `ruby` sitting in that slot the pane has no agent, so none of its
    # detection runs and the tab loses the working spinner and the blocked
    # marker. The name is all it needs; state it reads off the screen and the
    # OSC title, both of which already come straight through us.
    #
    # This throws our own command line away, which is why Handoff wrote it down
    # first.
    def adopt_child_name
      Handoff.write(@origin)
      Process.setproctitle(File.basename(@argv.first.to_s))
    rescue StandardError
      nil
    end

    def child_rows
      [@rows - @bar_rows, 1].max
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # -- screen ------------------------------------------------------------

    def enter_screen
      emit "\e[2J\e[H"
      set_region
      draw_bar
    end

    def leave_screen
      emit "\e[r"                              # full screen back
      emit "\e[#{child_rows + 1};1H\e[J"       # erase the bar, park the cursor
      emit "\e[?25h"                           # the child may have hidden it
    end

    def set_region
      emit "\e[1;#{child_rows}r"
    end

    def resize_child
      @pty_out.winsize = [child_rows, @cols]
    rescue SystemCallError
      nil
    end

    # Painted in one write so the cursor never visibly detours through the bar.
    #
    # The region is reset before addressing the bar rows and re-asserted after:
    # that keeps them reachable if the child turned on origin mode, and undoes
    # any scroll region the child set for itself (a full-screen `ESC[r` from the
    # child would otherwise let its scrolling eat the bar).
    #
    # DECSC/DECRC (ESC7/ESC8) is the only way to get the cursor back without
    # emulating the child's screen. The terminal has a single save slot, so a
    # child holding a saved cursor across this point would lose it - drawing
    # only once output has settled makes that vanishingly rare in practice.
    def draw_bar
      lines = bar_lines
      resize_bar(lines.size)

      out = +"\e7\e[r"
      lines.first(@bar_rows).each_with_index do |line, i|
        out << "\e[#{child_rows + 1 + i};1H\e[K" << line
      end
      out << "\e[1;#{child_rows}r\e8"
      emit out

      @dirty    = false
      @drawn_at = now
    end

    # The prompt history, or the last ! command's output while one is up. Both
    # are painted the same way; only the number of rows differs.
    def bar_lines
      @pane ? @pane.lines(@cols, max_bar) : @keys.lines(@cols)
    end

    def max_bar
      [@rows - MIN_CHILD, 2].max
    end

    # A taller bar moves the line the child ends on, so the scroll region and
    # the child's own idea of the screen have to move with it. Rows handed back
    # still have our text on them and the child has no reason to touch them
    # until it repaints, so clear them on the way out.
    def resize_bar(rows)
      rows = rows.clamp(1, max_bar)
      return if rows == @bar_rows

      back      = @bar_rows - rows      # positive when the bar shrinks
      @bar_rows = rows

      if back.positive?
        out = +"\e7\e[r"
        (child_rows - back + 1..child_rows).each { |row| out << "\e[#{row};1H\e[K" }
        emit out << "\e8"
      end

      set_region
      resize_child   # the kernel SIGWINCHes the child, which repaints itself
    end

    def emit(str)
      $stdout.write(str)
    end

    def apply_winch
      @winch = false
      rows, cols = $stdout.winsize
      return if rows.to_i.zero? || cols.to_i.zero?

      @rows, @cols = rows, cols
      resize_child   # the kernel SIGWINCHes the child off the back of this
      set_region
      draw_bar
    end

    # -- pump --------------------------------------------------------------

    def pump
      loop do
        apply_winch if @winch

        ready = IO.select([$stdin, @pty_out], nil, nil, IDLE_TICK)

        unless ready
          paint if @dirty   # output settled
          next
        end

        ready[0].each do |io|
          if io.equal?($stdin)
            data = slurp($stdin) or return
            taking = capture?

            # KeyBuffer decides what the child is allowed to see: everything,
            # unless a ! line is being typed, which is ours from the ! to the
            # Enter. Nothing is captured at all while the child is asking for a
            # password, and then it gets the bytes untouched.
            if taking
              @dirty = true if @keys.feed(data)
              @pty_in.write(@keys.pass) unless @keys.pass.empty?
            else
              @pty_in.write(data)
            end

            trace_in(data, taking)

            # After the trace, so the log shows the line that ran before its
            # output arrives, and after the write, so nothing waits on a shell.
            if taking
              @keys.bangs.each { |cmd| run_bang(cmd) }
              close_pane if @keys.typing?
            end
          else
            data = drain(@pty_out) or return
            $stdout.write(data)
            @out.feed(data)
            trace_out(data)
            # The child cannot address the bar rows, but it can switch to the
            # alt screen (which starts blank) or scroll a region it set itself.
            # Repainting after every burst heals both.
            @dirty = true
          end
        end

        # Keep the bar honest while output streams without ever settling.
        paint if @dirty && now - @drawn_at > MAX_DEFER
      end
    rescue Errno::EIO, Errno::EPIPE, EOFError
      nil
    end

    # A ! line never went to the child, so this is the whole of it: run it here
    # and put the result in the bar. A bare ! puts the bar back to the prompt
    # history, which is how you close the output without running anything.
    #
    # The pump is stopped while the shell runs, which is why Bang keeps a
    # deadline on it. The command is painted before it runs so a slow one does
    # not look like a hung terminal.
    def run_bang(cmd)
      return close_pane if cmd.empty?

      @pane  = Bang.pending(cmd)
      @dirty = true
      paint

      @pane = Bang.run(cmd)
      trace('BANG', "#{cmd.inspect} -> exit=#{@pane.status.inspect} #{@pane.note}")
      @dirty = true
      paint
    end

    # The first keystroke of the next line takes the screen back: the output was
    # for the question you were about to ask, and now you are asking it.
    def close_pane
      return unless @pane

      @pane  = nil
      @dirty = true
    end

    def slurp(io)
      io.readpartial(CHUNK)
    rescue EOFError, Errno::EIO, IOError
      nil
    end

    # Take everything the child has queued, not just the kilobyte a pty master
    # gives back per read. One redraw then lands in a single write and the paint
    # that follows it falls on a frame boundary instead of inside the frame.
    def drain(io)
      data = slurp(io) or return nil

      while data.bytesize < DRAIN_MAX && IO.select([io], nil, nil, 0)
        more = slurp(io) or break
        data << more
      end

      data
    end

    # Paint only where the terminal's parser is at rest - see OutScan for what
    # goes wrong otherwise. The bar is cosmetic, so waiting is nearly always
    # right; the exception is a child that leaves a sequence open for good (an
    # unterminated OSC, a DECSC it never restores), where a bar frozen on the
    # wrong prompts is worse than one glitched frame.
    def paint
      return released if @out.safe?

      @blocked ||= now

      if now - @blocked < MAX_BLOCK
        # Once per state rather than once per tick, or the log is nothing else.
        reason   = @out.to_s
        trace('SKIP', reason) if reason != @skipped
        @skipped = reason
        return
      end

      trace('FORCE', @out.to_s)
      @out.reset!
      released
    end

    def released
      @blocked = nil
      @skipped = nil
      draw_bar
    end

    # Terminals disagree wildly about how they report keys, and the encoding
    # depends on modes the child turns on and off as it runs. LLM_WRAP_DEBUG=<file>
    # records both sides raw so the two can be lined up. Off unless asked for -
    # it necessarily writes down every keystroke.
    #
    #   IN  <t> <bytes>  take=.. echo=.. canon=..  buf=<line so far>
    #   OUT <t> <mode sequences the child just set/reset>
    def trace(kind, text)
      return unless @trace

      @trace.write(format("%9.3f %-3s %s\n", now - @started, kind, text))
      @trace.flush
    rescue IOError, SystemCallError
      @trace = nil
    end

    def trace_in(data, taking)
      return unless @trace

      echo, canon = Termios.state(@pty_out)
      trace('IN', "#{data.inspect} take=#{taking} echo=#{echo} canon=#{canon} " \
                  "buf=#{@keys.pending.inspect}")
    end

    # Only the mode-setting sequences, not the whole output stream - the render
    # traffic would bury the log, and it is the modes that decide how the
    # terminal encodes keys in the first place.
    def trace_out(data)
      return unless @trace

      seqs = data.scan(/\e\[\?[\d;]+[hl]|\e\[[<>][\d;]*[a-zA-Z]/)
      trace('OUT', seqs.uniq.map(&:inspect).join(' ')) unless seqs.empty?
    end

    # Don't pin what the user cannot see themselves. Echo off while the child
    # is still canonical is a password prompt (sudo, ssh); echo off with
    # canonical also off is just a TUI in raw mode, which is the normal case.
    def capture?
      echo, canonical = Termios.state(@pty_out)
      return true if echo.nil?

      echo || !canonical
    end

    def reap
      _, status = Process.waitpid2(@pid)
      status.exitstatus || (128 + status.termsig.to_i)
    rescue Errno::ECHILD
      0
    end
  end

  # Follows the child's output on its way to the screen and answers one
  # question: is the terminal's parser at rest right now?
  #
  # Painting the bar means writing our own escapes into that stream, and a pty
  # master hands back at most a kilobyte per read - so a full redraw arrives as
  # dozens of pieces split at arbitrary bytes, and a paint dropped into one of
  # the seams breaks whatever it landed in the middle of:
  #
  #   * a sequence, leaving the introducer stranded and its tail printed as
  #     text - the literal "[22m" on screen
  #   * a UTF-8 character, which comes out as a replacement glyph
  #   * a DECSC the child opened and has not closed yet. The terminal has one
  #     save slot; we take it, and the child's own ESC8 then puts its cursor on
  #     our bar and it draws the rest of the frame over the top. Claude Code
  #     wraps every repaint in ESC7 ... ESC8, so this one is not theoretical.
  #
  # This is only ever asked about the *end* of what we have written so far, so
  # there is no need to understand the sequences - just to know where they stop.
  class OutScan
    ESC = 0x1b
    BEL = 0x07

    # Escapes whose second byte is followed by exactly one more: SS3 (ESC O),
    # the charset designators (ESC ( ) * +), and ESC # / ESC %.
    ONE_MORE ||= [0x4f, 0x28, 0x29, 0x2a, 0x2b, 0x23, 0x25].freeze

    # Runaway guards. A CSI this long, or a string payload this long, is a
    # stream we have lost the thread of rather than a sequence still coming.
    MAX_CSI ||= 128
    MAX_STR ||= 8192

    # Nothing outside these bytes can start a sequence or a multi-byte
    # character, so a plain-text burst needs no walking at all.
    INTERESTING ||= /[\e\x80-\xff]/n

    def initialize
      reset!
    end

    def reset!
      @state = :text
      @need  = 0     # UTF-8 continuation bytes still owed
      @saved = 0     # ESC7 seen without its ESC8
      @len   = 0
    end

    # True when the last byte written ended a sequence and a character, and the
    # child is not holding a saved cursor.
    def safe?
      @state == :text && @need.zero? && @saved.zero?
    end

    def feed(bytes)
      return if @state == :text && @need.zero? && !bytes.match?(INTERESTING)

      bytes.each_byte { |b| step(b) }
    end

    # What is holding a paint back, for the debug trace.
    def to_s
      "#{@state} utf8=#{@need} saved=#{@saved}"
    end

    private

    def step(byte)
      case @state
      when :text then text(byte)
      when :esc  then escape(byte)
      when :csi  then csi(byte)
      when :one  then @state = :text
      when :str  then string(byte)
      when :st   then terminator(byte)
      end
    end

    def text(byte)
      return @state = :esc if byte == ESC
      return @need = 0 if byte < 0x80

      # A continuation byte only counts while one is owed; anything else is a
      # lead byte, and a stray one just resets the count.
      return @need -= 1 if @need.positive? && (byte & 0xc0) == 0x80

      @need = case byte
              when 0xc0..0xdf then 1
              when 0xe0..0xef then 2
              when 0xf0..0xf7 then 3
              else 0
              end
    end

    # The second byte says how the rest of the sequence ends. ESC7/ESC8 are the
    # pair we care about beyond that - see the class comment.
    def escape(byte)
      @len = 0

      case byte
      when 0x5b          then @state = :csi
      when *STRING_INTRO then @state = :str
      when *ONE_MORE     then @state = :one
      when ESC           then nil                     # ESC ESC: still :esc
      else
        # ESC7 saves the cursor and ESC8 restores it. Everything else that gets
        # here is a two-byte escape, and is over.
        @saved += 1 if byte == 0x37
        @saved -= 1 if byte == 0x38 && @saved.positive?
        @state = :text
      end
    end

    def csi(byte)
      @len += 1
      return @state = :esc if byte == ESC       # aborted, a new one starting
      return @state = :text if @len > MAX_CSI

      @state = :text if byte >= 0x40 && byte <= 0x7e
    end

    # String payloads run to BEL or ST (ESC \).
    def string(byte)
      @len += 1
      return @state = :st   if byte == ESC
      return @state = :text if byte == BEL || @len > MAX_STR
    end

    def terminator(byte)
      return if byte == ESC

      @state = byte == 0x5c ? :text : :str
    end
  end

  # What a ! command left behind, as rows for the bar.
  #
  # It stays on this side of the wrapper. Nothing is typed into the child, so
  # the output is not in the transcript and not in the model's context - and it
  # is not painted over either, because these rows are outside the child's
  # screen by construction, the same trick that keeps the prompt history safe.
  class Pane
    include Text

    LABEL ||= 'shell'

    attr_reader :cmd, :pwd, :out, :status, :note

    def initialize(cmd, out: [], status: nil, note: nil)
      @cmd    = cmd
      @pwd    = Dir.pwd
      @out    = out
      @status = status
      @note   = note
    end

    # Where it ran, what ran, then what it printed - under a rule saying whose
    # rows these are. `max` is everything the bar is allowed to take.
    #
    # The command keeps the ! you typed rather than wearing a shell's $: it is
    # the same row you were just looking at while typing it, and the bar is a
    # record of what you typed.
    def lines(cols, max)
      head = [dim(clip(tilde(@pwd), cols)),
              "#{YELLOW}!#{RESET} #{clip(@cmd, cols - 2)}"]
      body = @out.empty? ? [dim('(no output)')] : @out.map { |line| clip(line, cols) }

      [rule(cols, label)] + head + fit(body, max - 1 - head.size)
    end

    private

    def label
      bits = [LABEL]
      bits << "exit #{@status}" if @status.to_i.positive?
      bits << @note if @note
      bits.join(' - ')
    end

    # Long output is cut from the bottom. The bar is a few rows and not a pager:
    # what is worth reading here a command says first, and anything else is a
    # pipe into head or a file away.
    def fit(rows, room)
      return rows if rows.size <= room
      return [] if room < 1

      rows.first(room - 1) << dim("… +#{rows.size - room + 1} more lines")
    end

    def tilde(path)
      home = Dir.home
      path.start_with?("#{home}/") || path == home ? path.sub(home, '~') : path
    end
  end

  # Runs a ! line, here, instead of handing it to the agent.
  module Bang
    # A ! line is meant to be quick, and the pump is stopped while it runs: no
    # keys reach the child and the screen does not repaint. Anything slower than
    # this wants to be a real terminal, or the agent's own tools.
    TIMEOUT ||= 10
    MAX_OUT ||= 65_536
    READ    ||= 4096

    # `cd` on its own, with nothing that would need a shell to work out. Every !
    # line gets a fresh shell, so a cd inside one dies with it and the pwd row
    # above the output would be a lie the moment you tried. Do it here instead.
    # This moves us and nothing else: the agent has its own working directory
    # and we are not reaching into it.
    CD ||= /\Acd(?:\s+(?<path>[^|&;<>()`$\n]*\S))?\z/

    # Yours, non-interactive - so zsh syntax works, but ~/.zshrc is not read and
    # your aliases and functions are not there. Loading it per line would cost
    # more than the round trip this is here to save.
    def self.shell
      sh = ENV['SHELL'].to_s
      sh.empty? ? '/bin/sh' : sh
    end

    def self.pending(cmd)
      Pane.new(cmd, note: 'running')
    end

    def self.run(cmd)
      cmd = cmd.strip
      (m = CD.match(cmd)) ? chdir(cmd, m[:path]) : capture(cmd)
    end

    def self.chdir(cmd, path)
      prev = Dir.pwd
      Dir.chdir(target(path))
      @back = prev
      Pane.new(cmd, status: 0)
    rescue SystemCallError => e
      Pane.new(cmd, out: [e.message], status: 1)
    end

    def self.target(path)
      case path
      when nil then Dir.home
      when '-' then @back || Dir.pwd
      else File.expand_path(path)
      end
    end

    def self.capture(cmd)
      out  = String.new(encoding: Encoding::BINARY)
      note = nil
      # No keyboard: our stdin is the terminal, in raw mode, and a command that
      # reads it would be taking the keystrokes meant for the agent. Anything
      # wanting input is not a ! line.
      io = IO.popen([shell, '-c', cmd], in: File::NULL, err: %i[child out], pgroup: true)
      till = clock + TIMEOUT

      loop do
        # Waiting on the pipe and not on the process: a command that forks and
        # leaves the pipe open (`something &`) holds this until the deadline,
        # and then it is stopped like anything else that overstayed.
        left = till - clock
        if left <= 0 || !IO.select([io], nil, nil, left)
          note = "timed out after #{TIMEOUT}s"
          break
        end

        begin
          out << io.readpartial(READ)
        rescue EOFError
          break
        end

        note = 'output cut' if out.bytesize >= MAX_OUT
        break if note
      end

      stop(io) if note
      Pane.new(cmd, out: rows(out), status: close(io), note: note)
    rescue SystemCallError, IOError => e
      Pane.new(cmd, out: [e.message], status: 1, note: 'did not run')
    end

    # Whatever it is doing, it does not get to outlive the line that started it -
    # the wrapper is not pumping keys while it lives. TERM first, then insist,
    # and the whole group because a shell -c is usually not the only process.
    def self.stop(io)
      Process.kill('TERM', -io.pid)
      sleep 0.05
      Process.kill('KILL', -io.pid)
    rescue SystemCallError
      nil
    end

    def self.close(io)
      io.close
      $?&.exitstatus
    rescue SystemCallError, IOError
      nil
    end

    def self.clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Output as bar rows: no escape sequences left to fight with our own colour
    # or walk the cursor out of the pane, and tabs where a terminal would put
    # them. The trailing newline every command ends with is not a blank row.
    def self.rows(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8).scrub('')
      out  = text.gsub(/\e\[[\d;?]*[ -\/]*[@-~]|\e[\]P^_X].*?(?:\a|\e\\)|\e./m, '')
                 .split("\n", -1)
                 .map { |line| untab(line).gsub(/[\x00-\x1f\x7f]/, '') }

      out.pop while !out.empty? && out.last.empty?
      out
    end

    def self.untab(line)
      return line unless line.include?("\t")

      line.each_char.with_object(+'') do |ch, out|
        ch == "\t" ? out << ' ' * (8 - (out.length % 8)) : out << ch
      end
    end
  end

  # Rebuilds the line you are typing from the raw byte stream on its way to the
  # child, and keeps the last `keep` submitted lines.
  #
  # In raw mode keystrokes usually arrive one at a time, but never rely on it:
  # reads can split a UTF-8 character or an escape sequence, so bytes are
  # accumulated in a binary buffer and only decoded when rendered.
  class KeyBuffer
    include Text

    MAX_LEN     ||= 4096
    NO_PROMPTS  ||= '(nothing typed yet)'
    LABEL       ||= 'prompt history'

    BANG  = 0x21
    CR    = 0x0d
    LF    = 0x0a
    ESC   = 0x1b
    TAB   = 0x09
    BS    = 0x08
    BEL   = 0x07
    DEL   = 0x7f

    CTRL_C = 0x03
    CTRL_U = 0x15
    CTRL_W = 0x17

    # Modifier bits, as reported by both keyboard protocols (1-based, so the
    # wire value is this + 1).
    SHIFT ||= 1
    ALT   ||= 2
    CTRL  ||= 4
    SUPER ||= 8

    # CSI <code>[:<alternates>][;<mods>[:<event>]][;<text codepoints>] u
    KITTY_KEY ||= /\A\e\[(\d+)(?::\d+(?::\d+)?)?(?:;(\d+)(?::(\d+))?)?(?:;([\d:]+))?u\z/
    # CSI 27 ; <mods> ; <code> ~   (xterm modifyOtherKeys)
    XTERM_KEY ||= /\A\e\[27;(\d+);(\d+)~\z/

    def initialize(keep)
      @keep    = keep
      @prompts = []
      @buf     = binary
      @esc     = nil
      @paste   = false
      @bang    = false
      @bangs   = []
      @pass    = binary
      @hold    = binary
    end

    # What the last feed decided, for the pump:
    #
    #   pass    the bytes the child is allowed to see. Everything, until a line
    #           starts with !, and then nothing until that line is done with.
    #   bangs   ! lines submitted in it, in order. An empty one is a bare !.
    #   typing? there is a line on the go, so the screen is wanted for it.
    attr_reader :pass, :bangs

    def typing? = !@buf.empty?
    def bang?   = @bang

    # The line being typed right now, for the debug trace.
    def pending
      decode(@buf)
    end

    # Returns true when what the bar shows changed.
    def feed(bytes)
      @pass    = binary
      @hold    = binary
      @bangs   = []
      changed  = false

      bytes.each_byte do |b|
        @hold << b
        was = @bang
        hit = @esc ? escape(b) : plain(b)
        # A ! line redraws on every keystroke: the bar is the only place it is
        # shown, so it has to keep up the way an input box would.
        changed = true if hit || @bang || was
        release unless @esc
      end

      release   # a sequence still arriving: the child waits no longer than today
      changed
    end

    # The whole bar, top to bottom: the labelled rule, then the pinned prompts
    # oldest first so the newest lands on the last line.
    def lines(cols)
      rows = Array.new(@keep) do |slot|
        age  = @keep - 1 - slot     # 0 is the newest, and it renders last
        text = @prompts[age]

        if text.nil?
          age.zero? ? "#{DIM}#{clip(NO_PROMPTS, cols)}#{RESET}" : ''
        elsif age.zero?
          "#{CYAN}❯#{RESET} #{clip(text, cols - 2)}"
        else
          "#{DIM}❯ #{clip(text, cols - 2)}#{RESET}"
        end
      end

      rows[-1] = typing(cols) if @bang
      [rule(cols, LABEL)] + rows
    end

    private

    # A ! line is not going anywhere near the child, so nothing else on screen
    # is showing it: this row is the only place you can see what you are typing,
    # cursor included. It takes the newest prompt's row, which comes back the
    # moment the line is run or dropped.
    def typing(cols)
      text = decode(@buf).delete_prefix('!').lstrip
      "#{YELLOW}!#{RESET} #{clip(text, cols - 4)}#{REV} #{RESET}"
    end

    # Bytes reach the child unless a ! line is holding them back. @swallow
    # carries the Enter that ended one, which is ours and not the child's.
    def release
      return if @hold.empty?

      @pass << @hold unless @bang || @swallow
      @swallow = false
      @hold    = binary
    end

    def binary
      String.new(encoding: Encoding::BINARY)
    end

    def plain(byte)
      case byte
      when ESC          then @esc = binary << byte; false
      when CR, LF       then @paste ? (append("\n"); false) : submit
      when DEL, BS      then chop_char; false
      when CTRL_U, CTRL_C then clear_line; false
      when CTRL_W       then drop_word; false
      when TAB          then false   # completion text is inserted by the app
      else
        append_byte(byte) if byte >= 0x20
        false
      end
    end

    # Collect an escape sequence, then decide. Everything is discarded except
    # the handful of forms that mean "newline, but do not submit" and the
    # bracketed-paste markers.
    def escape(byte)
      @esc << byte

      if @esc.bytesize == 2
        case byte
        when 0x5b, 0x4f    then return false       # CSI / SS3: keep collecting
        when *STRING_INTRO then return false       # OSC / DCS / APC / PM / SOS
        when CR, LF        then @esc = nil; append("\n"); return false # Option+Enter
        else @esc = nil; return false
        end
      end

      intro = @esc.getbyte(1)

      # String sequences run to BEL or ST (ESC \) rather than a final byte, and
      # carry a payload of printable text. They are the terminal answering a
      # question the program asked - Codex queries the fg/bg colour on startup
      # and gets back "\e]10;rgb:cdcd/d6d6/f4f4\e\\" - so the whole thing is
      # dropped. Treating them as CSI would spill that payload into the prompt.
      if STRING_INTRO.include?(intro)
        @esc = nil if byte == BEL || (byte == 0x5c && @esc.getbyte(-2) == ESC)
        @esc = nil if @esc && @esc.bytesize > 1024  # unterminated: cut losses
        return false
      end

      if intro == 0x4f                             # SS3 is always three bytes
        @esc = nil
        return false
      end

      if byte >= 0x40 && byte <= 0x7e              # CSI final byte
        seq = @esc
        @esc = nil
        return csi(seq)
      end

      @esc = nil if @esc.bytesize > 32             # runaway guard
      false
    end

    # Keys do not always arrive as plain bytes. Claude Code turns on both the
    # kitty keyboard protocol (CSI > 1 u) and xterm's modifyOtherKeys level 2
    # (CSI > 4 ; 2 m), under which the terminal reports keys as escape
    # sequences instead - so "hello" can arrive as five CSI sequences and a
    # parser that only reads raw bytes sees nothing at all.
    #
    # Everything else (arrows, function keys, focus in/out, and the SGR mouse
    # reports that Claude's motion tracking produces by the hundred) is
    # discarded: it is not text the user typed.
    def csi(seq)
      case seq
      when "\e[200~" then @paste = true
      when "\e[201~" then @paste = false
      when KITTY_KEY                        # CSI code[:alt][;mods[:event]][;text] u
        m = Regexp.last_match
        return key(m[1].to_i, m[2].to_i, event: m[3].to_i, text: m[4])
      when XTERM_KEY                        # CSI 27 ; mods ; code ~
        m = Regexp.last_match
        return key(m[2].to_i, m[1].to_i)
      end
      false
    end

    # One decoded keypress. `mods` is the usual 1-based bitfield (1 = none,
    # +1 shift, +2 alt, +4 ctrl, +8 super); caps/num lock are masked off so a
    # stuck caps lock does not turn every Enter into a continuation.
    def key(code, mods, event: 0, text: nil)
      return false if event == 3                     # key release, not a press

      bits = [mods - 1, 0].max & (SHIFT | ALT | CTRL | SUPER)

      case code
      when 13, 10 then return bits.zero? ? submit : (append("\n"); false)
      when 127, 8 then chop_char; return false
      when 9, 27  then return false                  # Tab, Esc
      end

      # Ctrl-<key> is a command, never text. Ctrl-V in particular pastes an
      # image in Claude Code, which puts no typed text on the wire at all.
      if bits & CTRL != 0
        case code
        when 117, 99 then clear_line                 # ctrl-u, ctrl-c
        when 119     then drop_word                  # ctrl-w
        end
        return false
      end
      return false if bits & (ALT | SUPER) != 0
      return false if code < 0x20

      # The kitty "associated text" field is the literal text of the keypress
      # and wins when present. Without it, shift lives in the modifiers while
      # `code` stays the unshifted key, so apply it by hand.
      if text
        text.split(':').each { |cp| append(cp.to_i.chr(Encoding::UTF_8)) }
      else
        ch = code.chr(Encoding::UTF_8)
        ch = ch.upcase if bits & SHIFT != 0
        append(ch)
      end
      false
    rescue RangeError
      false
    end

    def append_byte(byte)
      return if byte == BANG && !bang_char

      @buf << byte if @buf.bytesize < MAX_LEN
    end

    def append(str)
      return if str == '!' && !bang_char

      @buf << str.b if @buf.bytesize < MAX_LEN
    end

    # A ! in the first column is ours: from here to Enter nothing reaches the
    # child and the line runs in a shell instead. Typed twice it is handed back,
    # so `!!ls` arrives at the agent as `!ls` and its own bash mode is still
    # there when that is what you wanted. A leading space is the other way out.
    #
    # False when the character has been dealt with and must not be appended.
    def bang_char
      if @bang && @buf == '!'.b
        @bang = false      # the second !: this one is the child's, and the
        return false       # buffer is already holding a ! for it
      end

      @bang = true if @buf.empty? && !@paste
      true
    end

    def clear_line
      end_bang
      @buf = binary
    end

    # Ending a ! line takes the keystroke that ended it along: a backspace or a
    # ctrl-c that cancelled one was editing our line and not the child's, and a
    # ctrl-c in particular would interrupt the agent over nothing.
    def end_bang
      return unless @bang

      @bang    = false
      @swallow = true
    end

    # Drop one whole character: back over any UTF-8 continuation bytes first.
    def chop_char
      return if @buf.empty?

      i = @buf.bytesize - 1
      i -= 1 while i.positive? && (@buf.getbyte(i) & 0xc0) == 0x80
      @buf.slice!(i..)
      end_bang if @buf.empty?
    end

    # Readline's unix-word-rubout: eat trailing whitespace, then the word, and
    # leave the separator before it alone ("one two" -> "one ").
    def drop_word
      @buf.sub!(/\s+\z/, '')
      @buf.sub!(/\S+\z/, '')
      end_bang if @buf.empty?
    end

    def submit
      text = decode(@buf)
      bang = @bang
      raw  = @buf
      clear_line

      # A ! line is not a prompt: it was never said to the agent, so it has no
      # business in a history of what was.
      if bang
        @bangs << command(raw)
        return true
      end

      return false if text.empty? || @prompts.first == text

      @prompts.unshift(text)
      @prompts.pop while @prompts.size > @keep
      true
    end

    # The line as a shell should see it, which is not how the bar sees it:
    # newlines are separators a shell understands and must survive whole.
    def command(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub('').strip.delete_prefix('!').strip
    end

    # A bar row is one line, so a multi-line prompt - a continuation with
    # Shift/Option+Enter, or a pasted block - is flattened onto it: line breaks
    # show as a backslash + space, and clip() caps the result to the terminal
    # width. Nothing is dropped that would still fit.
    def decode(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8).scrub('').strip
      return '' if text.empty?

      text.gsub(/[^\S\n]+/, ' ')        # runs of spaces/tabs, newlines kept
          .gsub(/ ?\n+ ?/) { '\ ' }     # block form: no backslash escaping here
    end
  end
end

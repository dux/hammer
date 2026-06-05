require 'io/console'

class Hammer
  # ANSI color/output helpers. Mixed into command instances; also callable
  # directly as `Hammer::Shell.say(...)`.
  module Shell
    COLORS ||= {
      black:   30, red:     31, green:   32, yellow:  33,
      blue:    34, magenta: 35, cyan:    36, white:   37,
      gray:    90
    }.freeze

    module_function

    def color?
      # Only an explicit color!(value) override is sticky; otherwise the
      # tty decision is recomputed so a redirected $stdout (tests, capture
      # blocks) is honored instead of frozen at first read.
      return @color if defined?(@color) && !@color.nil?
      $stdout.tty? && ENV['NO_COLOR'].nil?
    end

    def color!(value)
      @color = value
    end

    def paint(text, color = nil)
      if color && !COLORS.key?(color)
        raise Hammer::Error, "unknown color #{color.inspect} (valid: #{COLORS.keys.join(', ')})"
      end
      return text.to_s unless color? && color
      "\e[#{COLORS[color]}m#{text}\e[0m"
    end

    # `say` with no args returns a proxy so you can write `say.cyan 'hi'`.
    # `say('')` still prints a blank line; `say('x', :cyan)` is unchanged.
    def say(text = :_say_no_arg, color = nil)
      return SayProxy.new if text == :_say_no_arg
      puts paint(text, color)
    end

    class SayProxy
      COLORS.each_key do |name|
        define_method(name) { |text = ''| Shell.say(text, name) }
      end

      def method_missing(name, *)
        raise Hammer::Error, "unknown color :#{name} (valid: #{COLORS.keys.join(', ')})"
      end

      def respond_to_missing?(_name, _include_private = false)
        false
      end
    end

    # Raise a controlled Hammer::Error. If unhandled, the dispatcher
    # prints the message in red and exits 1 - no backtrace, no help spam.
    #
    #   error 'config file missing' unless File.exist?(path)
    def error(text)
      raise Hammer::Error, text
    end

    # Print a red [error] line to stderr (does not exit). Used internally
    # by the dispatcher to render Hammer::Error messages.
    def print_error(text)
      warn paint("[error] #{text}", :red)
    end

    def ask(prompt, default: nil)
      suffix = default ? " [#{default}]" : ''
      print paint("#{prompt}#{suffix}: ", :cyan)
      line = $stdin.gets
      return default if line.nil?
      line = line.chomp
      line.empty? ? default : line
    end

    def yes?(prompt)
      answer = ask("#{prompt} (y/N)")
      return false if answer.nil?
      answer.to_s.strip.downcase.start_with?('y')
    end

    # Arrow-key picker. Returns the chosen index, or nil on cancel
    # (ESC, Ctrl-C, q). Non-TTY input falls back to a numbered prompt
    # so this stays scriptable.
    #
    #   idx = choose 'Pick env', %w[dev staging prod]
    #   say.green "chose #{ %w[dev staging prod][idx] }" if idx
    def choose(prompt, items)
      items = items.to_a
      error 'choose needs at least one item' if items.empty?

      say.cyan prompt

      return choose_numbered(items) unless $stdin.tty? && $stdin.respond_to?(:raw)

      selected = 0
      # In raw mode \n is not translated to \r\n, so the picker uses \r\n
      # explicitly. The initial draw happens in cooked mode but \r\n is
      # harmless there.
      redraw = lambda do |highlight = :cyan|
        items.each_with_index do |item, i|
          line = i == selected ? paint("> #{item}", highlight) : "  #{item}"
          $stdout.print "#{line}\r\n"
        end
      end
      redraw.call

      $stdout.print "\e[?25l" # hide cursor
      begin
        $stdin.raw do |io|
          loop do
            ch = io.getch
            case ch
            when "\r", "\n"
              # Collapse the list to the chosen line, in green.
              $stdout.print "\e[#{items.size}A\r\e[J"
              $stdout.print "#{paint("> #{items[selected]}", :green)}\r\n"
              return selected
            when "\x03" # Ctrl-C
              $stdout.print "\e[#{items.size}A\r\e[J"
              raise Interrupt
            when "\e"
              # ESC may stand alone or start an arrow sequence \e[A / \e[B.
              if IO.select([io], nil, nil, 0.01) && io.getch == '['
                case io.getch
                when 'A' then selected = (selected - 1) % items.size
                when 'B' then selected = (selected + 1) % items.size
                end
              else
                $stdout.print "\e[#{items.size}A\r\e[J"
                return nil
              end
            when 'k' then selected = (selected - 1) % items.size
            when 'j' then selected = (selected + 1) % items.size
            end
            $stdout.print "\e[#{items.size}A\r\e[J"
            redraw.call
          end
        end
      ensure
        $stdout.print "\e[?25h" # show cursor
      end
    end

    # Fallback for non-TTY stdin (pipes, tests). Returns the index or nil.
    def choose_numbered(items)
      items.each_with_index { |item, i| puts "  #{i + 1}) #{item}" }
      print paint("select [1-#{items.size}]: ", :cyan)
      line = $stdin.gets
      return nil if line.nil?
      idx = line.strip.to_i - 1
      idx.between?(0, items.size - 1) ? idx : nil
    end

    # Run a shell command. Echoes the command in gray, raises
    # Hammer::Error on non-zero exit. Returns true on success.
    def sh(cmd)
      say "$ #{cmd}", :gray
      error "command failed: #{cmd}" unless system(cmd)
      true
    end
  end
end

# `"hi".color(:cyan)` -> ANSI-painted string. Raises on unknown color.
class String
  def color(name)
    Hammer::Shell.paint(self, name)
  end
end

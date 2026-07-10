class Hammer
  # A single registered command on a Hammer class.
  class Command
    attr_reader :name, :desc, :options, :examples, :alts, :needs, :cron
    attr_accessor :handler, :location, :prev_location

    def initialize(name:, desc: '', handler: nil)
      @name     = name.to_s
      @desc     = desc.to_s.rstrip
      @handler  = handler
      @options  = []
      @examples = []
      @alts     = []
      @needs    = []
    end

    # First line of `desc`, used in the flat command listing.
    def brief
      @desc.lines.first&.chomp.to_s
    end

    def add_option(option)
      @options << option
    end

    def add_example(text)
      @examples << text.to_s
    end

    def add_alt(name)
      @alts << name.to_s
    end

    def add_need(name)
      @needs << name.to_s
    end

    # Store a `cron '<expr>'` schedule. The raw string is kept for
    # display/export; parsing happens here so an invalid expression
    # raises Hammer::Error at definition time, not when the job server
    # starts. The parsed Hammer::Cron is what the scheduler consumes.
    def set_cron(expr)
      @cron_schedule = Hammer::Cron.new(expr)
      @cron = @cron_schedule.source
    end

    def cron_schedule
      @cron_schedule
    end

    def matches?(name)
      name = name.to_s
      name == @name || @alts.include?(name)
    end

    # Auto-assign a single-letter short alias (first letter of the opt
    # name) to any opt that does not already declare one. Explicit
    # aliases and `-h` are reserved first, so they always win. On
    # collision the opt simply gets no short form - long flag still
    # works. Idempotent.
    def finalize!
      return if @finalized
      @finalized = true

      claimed = ['-h']
      @options.each do |o|
        o.aliases.each { |a| claimed << a if short_flag?(a) }
      end

      @options.each do |o|
        next if o.aliases.any? { |a| short_flag?(a) }
        short = "-#{o.name.to_s[0]}"
        next if claimed.include?(short)
        o.aliases << short
        claimed << short
      end
    end

    # Structured form for JSON export (`h:json`). `path` is the full
    # colon path supplied by the tree walk - a Command doesn't know its
    # own namespace prefix. `hidden` follows the help rule: a task with
    # no `desc` still dispatches but is hidden from listings.
    def to_h(path = name)
      {
        name:      name,
        path:      path,
        desc:      desc,
        brief:     brief,
        hidden:    desc.empty?,
        redefined: !prev_location.nil?,
        location:  location,
        alts:      alts,
        needs:     needs,
        cron:      cron,
        examples:  examples,
        options:   options.map(&:to_h)
      }
    end

    private

    def short_flag?(switch)
      switch.length == 2 && switch.start_with?('-') && switch[1] != '-'
    end
  end
end

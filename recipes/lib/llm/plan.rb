# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# Applies a /plan bundle - a JSON file that pairs every intended edit with the
# sha1 its target had when the plan was written.
#
# The point is a fast apply after slow planning: a file whose sha1 still
# matches is written without anyone re-reading it, and a file that drifted is
# handed back to the caller with the intent and the wanted text, to be applied
# by judgement instead of by string match. Nothing here calls an LLM; it tells
# the one that is already running what is left to do.
#
# Safety rules that hold regardless of the bundle:
#   - a file is only written once every hunk in it resolves, so no file is
#     ever left half-edited
#   - writes go through a temp file and a rename, keeping the original mode
#   - every touched file is copied under <slug>.bak before it changes, and the
#     undo log is flushed per file so a crash mid-run is still revertible
#   - paths must stay inside the working tree and may not be symlinks
#   - a bundle that already landed re-runs as a no-op, not as drift
module LlmPlan
  Error = Class.new(StandardError)

  # One planned file operation, plus everything needed to decide whether the
  # world still looks the way the plan assumed.
  class Entry
    OPS          = %w[create change delete].freeze
    PAST         = { 'create' => 'created', 'change' => 'changed', 'delete' => 'deleted' }.freeze
    ANCHOR_WIDTH = 60

    attr_reader :path, :op, :sha1

    def initialize(raw, root:)
      @raw  = raw
      @root = root
      @path = raw['path'].to_s
      @op   = raw['op'].to_s
      @sha1 = raw['sha1'].to_s
      validate!
    end

    def hunks   = Array(@raw['hunks'])
    def content = @raw['content'].to_s
    def past    = PAST[op]

    # sha1 of the file as it is right now, or nil when it is not there.
    def current_sha1
      File.file?(abs) ? Digest::SHA1.file(abs).hexdigest : nil
    end

    # nil when the file is byte for byte what the plan assumed, otherwise a
    # sentence the caller can act on.
    def drift_reason
      return "#{path} is a symlink, refusing to write through it" if File.symlink?(abs)

      if op == 'create'
        return nil unless File.exist?(abs)
        'planned as a new file, but it exists now'
      else
        return 'planned file is gone' unless File.file?(abs)
        got = current_sha1
        return nil if got == sha1
        "changed since planning (sha1 #{got[0, 10]}, planned #{sha1[0, 10]})"
      end
    end

    # A second run of a bundle that already landed is a no-op, not drift.
    # `record` is this entry's line from the undo log, or nil.
    def already_applied?(record)
      return false unless record
      return !File.exist?(abs) if op == 'delete'
      current_sha1 == record['after']
    end

    # Writes the entry. Returns nil on success, or a reason string naming what
    # the caller has to finish by hand.
    def apply!(backup)
      case op
      when 'create'
        FileUtils.mkdir_p File.dirname(abs)
        write content
      when 'delete'
        backup.save abs, path
        FileUtils.rm_f abs
      when 'change'
        body = File.read(abs)

        # Resolve every hunk against the in-memory copy first - a bundle with
        # one bad anchor leaves the file exactly as it was.
        hunks.each do |hunk|
          body, reason = splice(body, hunk)
          return reason if reason
        end

        backup.save abs, path
        write body
      end

      nil
    end

    private

    def abs = File.expand_path(path, @root)

    def validate!
      raise Error, 'file entry without a path'                if path.empty?
      raise Error, "#{path}: unknown op #{op.inspect}"         unless OPS.include?(op)
      raise Error, "#{path}: absolute paths are not allowed"   if path.start_with?('/')
      raise Error, "#{path}: path escapes the working tree"    unless inside_root?
      raise Error, "#{path}: create needs content"             if op == 'create' && !@raw.key?('content')
      raise Error, "#{path}: #{op} needs a sha1"               if op != 'create' && sha1.empty?
      raise Error, "#{path}: change needs at least one hunk"   if op == 'change' && hunks.empty?

      hunks.each do |hunk|
        raise Error, "#{path}: hunk needs both old and new"    unless hunk['old'] && hunk['new']
        raise Error, "#{path}: hunk old and new are identical" if hunk['old'] == hunk['new']
        raise Error, "#{path}: hunk old is empty"              if hunk['old'].to_s.empty?
      end
    end

    def inside_root?
      File.expand_path(path, @root).start_with?("#{@root}/")
    end

    # Block form of sub/gsub on purpose: a replacement passed as a string would
    # read \1 and \& in the new text as backreferences.
    def splice(body, hunk)
      old, new = hunk['old'].to_s, hunk['new'].to_s
      found    = body.scan(old).size

      if hunk['all']
        return [body, "anchor never matched: #{anchor(old)}"] if found.zero?
        [body.gsub(old) { new }, nil]
      else
        return [body, "anchor matched #{found} times, needs exactly 1: #{anchor(old)}"] unless found == 1
        [body.sub(old) { new }, nil]
      end
    end

    def anchor(text)
      line = text.lines.first.to_s.strip
      line.length > ANCHOR_WIDTH ? "#{line[0, ANCHOR_WIDTH - 3]}..." : line
    end

    def write(body)
      body += "\n" unless body.empty? || body.end_with?("\n")

      mode = File.exist?(abs) ? File.stat(abs).mode : nil
      tmp  = "#{abs}.llm-plan.#{Process.pid}"

      File.write tmp, body
      File.chmod mode, tmp if mode
      File.rename tmp, abs
    ensure
      FileUtils.rm_f tmp if tmp && File.exist?(tmp)
    end
  end

  # Copies of everything a run touched, plus the log that says how to undo it.
  class Backup
    LOG = '_applied.json'

    def initialize(dir, root:)
      @dir  = dir
      @root = root
      @log  = read_log
    end

    def record_for(entry)
      @log.find { |row| row['path'] == entry.path }
    end

    def save(abs, path)
      return unless File.exist?(abs)

      dest = File.join(@dir, path.sub(%r{\A\./}, ''))
      FileUtils.mkdir_p File.dirname(dest)
      FileUtils.cp abs, dest
    end

    # Flushed per entry, so an interrupted run is still fully revertible.
    def note(entry)
      @log.reject! { |row| row['path'] == entry.path }
      @log.push 'path' => entry.path, 'op' => entry.op, 'after' => entry.current_sha1

      FileUtils.mkdir_p @dir
      File.write File.join(@dir, LOG), "#{JSON.pretty_generate(@log)}\n"
    end

    # Undoes a run: created files go away, changed and deleted files come back
    # from the copies. Returns the paths it touched.
    def restore!
      raise Error, "no backup at #{@dir}" if @log.empty?

      @log.map do |row|
        path = row['path']
        abs  = File.expand_path(path, @root)

        if row['op'] == 'create'
          FileUtils.rm_f abs
        else
          src = File.join(@dir, path.sub(%r{\A\./}, ''))
          raise Error, "backup copy missing for #{path}" unless File.exist?(src)
          FileUtils.mkdir_p File.dirname(abs)
          FileUtils.cp src, abs
        end

        path
      end
    end

    private

    def read_log
      file = File.join(@dir, LOG)
      File.exist?(file) ? JSON.parse(File.read(file)) : []
    rescue JSON::ParserError
      []
    end
  end

  # The bundle file: what to do, how to prove it, and what to call the commit.
  class Bundle
    attr_reader :path, :slug, :goal, :entries, :verify_commands

    def initialize(path, root: Dir.pwd)
      @path = File.expand_path(path)
      @root = File.expand_path(root)
      raise Error, "no bundle at #{path}" unless File.file?(@path)

      raw              = parse
      @slug            = raw['slug'].to_s.empty? ? File.basename(@path, '.json') : raw['slug']
      @goal            = raw['goal'].to_s
      @commit          = raw['commit'] || {}
      @verify_commands = Array(raw['verify'])
      @entries         = Array(raw['files']).map { |file| Entry.new(file, root: @root) }

      raise Error, 'bundle lists no files' if @entries.empty?
      raise Error, "duplicate path in bundle: #{duplicate}" if duplicate
    end

    def backup_dir   = File.join(dir, "#{slug}.bak")
    def message_path = File.join(dir, "#{slug}.msg")

    # Subject and body separated by the blank line git expects.
    def commit_message
      [@commit['subject'], @commit['body']].map { |part| part.to_s.strip }.reject(&:empty?).join("\n\n")
    end

    def write_commit_message!
      return if commit_message.empty?
      File.write message_path, "#{commit_message}\n"
    end

    private

    def dir = File.dirname(@path)

    def parse
      JSON.parse File.read(@path)
    rescue JSON::ParserError => e
      raise Error, "bundle is not valid json: #{e.message}"
    end

    def duplicate
      seen = {}
      @entries.each do |entry|
        return entry.path if seen[entry.path]
        seen[entry.path] = true
      end
      nil
    end
  end

  Applied = Struct.new(:entry, :note)
  Drifted = Struct.new(:entry, :reason)
  Verify  = Struct.new(:ok, :failed_command)

  # What one run did. `exit_code` is the whole contract with the shell.
  class Outcome
    attr_reader :bundle, :applied, :drifted, :skipped
    attr_accessor :verify

    def initialize(bundle:, applied:, drifted:, skipped:, check_only:)
      @bundle     = bundle
      @applied    = applied
      @drifted    = drifted
      @skipped    = skipped
      @check_only = check_only
    end

    def check_only? = @check_only
    def clean?      = @drifted.empty?
    def touched?    = @applied.any?

    def exit_code
      return 10 unless clean?
      return 20 if verify && !verify.ok
      0
    end
  end

  # Drives a bundle. Prints nothing - the caller owns the terminal.
  class Runner
    def initialize(bundle, root: Dir.pwd)
      @bundle = bundle
      @root   = File.expand_path(root)
      @backup = Backup.new(bundle.backup_dir, root: @root)
    end

    def apply(check_only: false)
      applied, drifted, skipped = [], [], []

      @bundle.entries.each do |entry|
        next skipped.push(entry) if entry.already_applied?(@backup.record_for(entry))

        reason = entry.drift_reason
        next drifted.push(Drifted.new(entry, reason)) if reason
        next applied.push(Applied.new(entry, 'would apply')) if check_only

        failure = entry.apply!(@backup)

        if failure
          drifted.push Drifted.new(entry, failure)
        else
          @backup.note entry
          applied.push Applied.new(entry, entry.past)
        end
      end

      @bundle.write_commit_message! if applied.any? && !check_only

      Outcome.new(bundle: @bundle, applied:, drifted:, skipped:, check_only:)
    end

    # Runs the verify commands in order, stopping at the first failure. Their
    # output streams straight through - the caller wants to read it. Yields
    # each command first so the caller can announce it.
    def verify
      @bundle.verify_commands.each do |cmd|
        yield cmd if block_given?
        return Verify.new(false, cmd) unless system(cmd)
      end

      Verify.new(true, nil)
    end

    def revert = @backup.restore!
  end

  # Turns an Outcome into lines of [text, color] for the CLI to print. Kept
  # apart from Runner so the wording is testable without a terminal.
  class Report
    def initialize(outcome)
      @outcome = outcome
    end

    def lines
      rows = []
      @outcome.applied.each { |applied| rows << ["  ok    #{applied.entry.path} (#{applied.note})", :green] }
      @outcome.skipped.each { |entry|   rows << ["  ok    #{entry.path} (already applied)", :gray] }
      rows << ['', nil] if rows.any? && @outcome.drifted.any?

      @outcome.drifted.each { |drifted| rows.concat drift_block(drifted) }
      rows.concat summary
      rows
    end

    private

    def drift_block(drifted)
      entry = drifted.entry
      rows  = [["  DRIFT #{entry.path}", :red],
               ["  #{drifted.reason}. apply this yourself against the current file:", :yellow]]

      case entry.op
      when 'delete'
        rows << ['  intent: delete this file - confirm that is still right', nil]
      when 'create'
        rows << ['  intent: this content was planned as new - merge it in', nil]
        rows << ['  --- wanted content ---', :gray]
        rows << [entry.content, nil]
        rows << ['  ----------------------', :gray]
      when 'change'
        entry.hunks.each do |hunk|
          rows << ["  intent: #{hunk['intent']}", nil] if hunk['intent']
          rows << ['  --- wanted old ---', :gray]
          rows << [hunk['old'], nil]
          rows << ['  --- wanted new ---', :gray]
          rows << [hunk['new'], nil]
          rows << ['  ------------------', :gray]
        end
      end

      rows << ['', nil]
      rows
    end

    def summary
      done = @outcome.applied.size + @outcome.skipped.size
      rows = [["  #{done} applied, #{@outcome.drifted.size} needs you", nil]]
      return rows if @outcome.check_only? || !@outcome.touched?

      rows << ["  backup: #{@outcome.bundle.backup_dir}/", :gray]
      rows << ["  revert: llm plan:revert #{@outcome.bundle.path}", :gray]
      rows
    end
  end
end

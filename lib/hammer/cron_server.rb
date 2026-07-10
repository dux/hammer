require 'json'
require 'fileutils'

class Hammer
  # The `hammer h:cron` job server. Discovers every task that declares a
  # `cron '<expr>'` schedule, ticks once per minute and runs each due job
  # in its own subprocess (a fresh `hammer ns:task`, exactly like the
  # macOS GUI runs tasks), streaming stdout+stderr into a per-job log.
  # A small web UI (Hammer::CronWeb) serves job status and logs on
  # localhost.
  #
  # On-disk layout, relative to the Hammerfile dir:
  #
  #   log/hammer/<slug>.log      current job log (db:backup -> db-backup.log)
  #   log/hammer/<slug>.log.1    previous log, rotation keeps max 2 files
  #   tmp/hammer/cron.state.json last-run timestamps + daemon pid/port
  class CronServer
    MAX_LOG_BYTES ||= 1_048_576   # rotate the job log past 1 MB

    # One scheduled task. `pid` doubles as the running flag: nil when
    # idle, :starting between due-check and spawn, then the child pid.
    Job = Struct.new(:path, :command, :schedule, :last_run, :status,
                     :exit_code, :duration, :pid, keyword_init: true) do
      def running?
        !pid.nil?
      end

      # Log-safe file name: 'db:backup' -> 'db-backup'.
      def file_slug
        path.tr(':', '-').gsub(/[^\w.-]/, '-')
      end
    end

    attr_reader :jobs, :port, :root_dir

    def initialize(root_klass, port:)
      @root_dir   = Dir.pwd   # Hammer.cli already chdir-ed to the Hammerfile dir
      @port       = port
      @hammer_bin = begin
        File.realpath($PROGRAM_NAME)
      rescue Errno::ENOENT
        File.expand_path($PROGRAM_NAME)
      end
      @log_dir    = File.join(@root_dir, 'log/hammer')
      @state_path = File.join(@root_dir, 'tmp/hammer/cron.state.json')
      @mutex      = Mutex.new
      @threads    = []

      @jobs = {}
      root_klass.each_command(include_builtins: false) do |path, cmd|
        next unless cmd.cron
        @jobs[path] = Job.new(path: path, command: cmd, schedule: cmd.cron_schedule)
      end
      if @jobs.empty?
        raise Hammer::Error,
              "no tasks declare a cron schedule - add `cron '*/10 * * * *'` (or '10m', '@daily') inside a task block"
      end

      load_state
    end

    # ----- foreground service --------------------------------------------

    # Run scheduler + web UI until SIGINT/SIGTERM. The scheduler owns the
    # main thread (so Ctrl-C lands in the thread that is sleeping); the
    # HTTP accept loop runs in a background thread. Trap handlers only
    # flip a flag - no IO or locking is allowed inside a trap.
    def run!
      ensure_single_instance!
      @stop = false
      trap('INT')  { @stop = true }
      trap('TERM') { @stop = true }

      save_state
      require_relative 'cron_web'
      @web = CronWeb.new(self, port: @port).start
      print_startup_summary
      Shell.say "web ui: http://127.0.0.1:#{@port}", :cyan
      Shell.say 'Ctrl-C to stop', :gray

      until @stop
        tick = wait_for_minute or break
        each_job_snapshot do |job|
          launch(job, tick, trigger: 'cron') if job.schedule.due?(tick, job.last_run)
        end
      end

      shutdown!
    end

    # Table of scheduled jobs + next runs; doubles as `h:cron --list`.
    def print_startup_summary
      now  = Time.now
      rows = @jobs.values.map do |job|
        [job.path, job.schedule.source, format_time(job.last_run),
         format_time(job.schedule.next_run(now, last_run: job.last_run))]
      end
      widths = ['task', 'schedule', 'last run', 'next run'].each_with_index.map do |h, i|
        [h.length, *rows.map { |r| r[i].length }].max
      end
      header = ['task', 'schedule', 'last run', 'next run']
      Shell.say header.each_with_index.map { |h, i| h.ljust(widths[i]) }.join('  '), :yellow
      rows.each do |r|
        Shell.say r.each_with_index.map { |v, i| v.ljust(widths[i]) }.join('  ')
      end
    end

    # Trigger one job outside its schedule (web UI "run now" button).
    # Same code path as a scheduled run; the log header says 'manual'.
    # Returns false when the job is unknown.
    def run_now(path)
      job = @jobs[path] or return false
      launch(job, Time.now, trigger: 'manual')
      true
    end

    # ----- job execution --------------------------------------------------

    # Fire one run in a subprocess. Overlap policy: if the previous run
    # of the SAME job is still alive, skip and note it in the job log -
    # jobs that outlive their interval must not pile up. Different jobs
    # run freely in parallel. The child runs the full normal hammer
    # pipeline (Bundler, dotenv, before hooks, needs) in @root_dir with
    # stdin closed, so anything interactive fails fast instead of
    # hanging the scheduler.
    def launch(job, at, trigger:)
      @mutex.synchronize do
        if job.running?
          append_line(job, "[h:cron] #{at.strftime('%F %T')} skipped (#{trigger}) - previous run still active")
          return
        end
        job.pid      = :starting
        job.status   = 'running'
        job.last_run = at
        save_state
      end

      @threads << Thread.new do
        begin
          rotate_log(job)
          FileUtils.mkdir_p(@log_dir)
          File.open(log_path(job), 'a') do |log|
            log.sync = true
            log.puts "===== #{job.path} | #{trigger} | #{at.strftime('%F %T')} ====="
            t0  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            pid = Process.spawn(
              { 'NO_COLOR' => '1', 'HAMMER_QUIET' => '1' },
              @hammer_bin, job.path,
              in: File::NULL, out: log, err: log, chdir: @root_dir
            )
            @mutex.synchronize { job.pid = pid }
            _, status = Process.wait2(pid)
            dur = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
            log.puts "===== exit #{status.exitstatus.inspect} | #{format('%.1f', dur)}s ====="
            @mutex.synchronize do
              job.pid       = nil
              job.exit_code = status.exitstatus
              job.duration  = dur
              job.status    = status.success? ? 'ok' : 'failed'
              save_state
            end
          end
        rescue => e
          @mutex.synchronize do
            job.pid    = nil
            job.status = 'error'
            save_state
          end
          append_line(job, "[h:cron] run failed: #{e.class}: #{e.message}")
        end
      end
    end

    # ----- logs -----------------------------------------------------------

    def log_path(job)
      File.join(@log_dir, "#{job.file_slug}.log")
    end

    # Called before each run: past 1 MB the current log rolls to .log.1
    # (POSIX rename clobbers the previous .1) and the run starts fresh.
    # Max two files per job, ever.
    def rotate_log(job)
      path = log_path(job)
      size = begin
        File.size(path)
      rescue Errno::ENOENT
        0
      end
      File.rename(path, "#{path}.1") if size > MAX_LOG_BYTES
    end

    # ----- state file -----------------------------------------------------

    # tmp/hammer/cron.state.json remembers last runs across restarts so a
    # relaunched scheduler neither re-fires jobs that just ran nor
    # forgets interval clocks. Also records our pid/port so a second
    # `h:cron` (and the web UI) can see who is running.
    def save_state
      data = {
        schema:     1,
        pid:        Process.pid,
        port:       @port,
        started_at: (@started_at ||= Time.now).to_i,
        jobs:       @jobs.transform_values do |j|
          { last_run: j.last_run&.to_i, exit: j.exit_code, duration: j.duration, status: j.status }
        end
      }
      FileUtils.mkdir_p(File.dirname(@state_path))
      tmp = "#{@state_path}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, @state_path)
    end

    # Tolerates a missing or corrupt file - scheduling state is
    # best-effort, a fresh start is always safe. Jobs no longer declared
    # in the Hammerfile simply are not restored (and get pruned on the
    # next save).
    def load_state
      data = begin
        JSON.parse(File.read(@state_path))
      rescue Errno::ENOENT
        return
      rescue JSON::ParserError
        warn Shell.paint("h:cron: ignoring corrupt #{@state_path}", :gray)
        return
      end
      @saved_pid = data['pid']
      (data['jobs'] || {}).each do |path, j|
        job = @jobs[path] or next
        job.last_run  = j['last_run'] ? Time.at(j['last_run']) : nil
        job.exit_code = j['exit']
        job.duration  = j['duration']
        job.status    = j['status']
      end
    end

    # ----- service units ---------------------------------------------------

    # Print a launchd plist (macOS) or systemd user unit (everything
    # else) for running `h:cron` supervised. Unit text goes to stdout so
    # it can be redirected into a file; install hints go to stderr.
    def print_service_unit
      if RUBY_PLATFORM.include?('darwin')
        label = "com.lux-hammer.cron.#{File.basename(@root_dir)}"
        puts <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>Label</key><string>#{label}</string>
            <key>ProgramArguments</key>
            <array>
              <string>#{@hammer_bin}</string>
              <string>h:cron</string>
              <string>--port=#{@port}</string>
            </array>
            <key>WorkingDirectory</key><string>#{@root_dir}</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>#{@root_dir}/log/hammer/cron-server.log</string>
            <key>StandardErrorPath</key><string>#{@root_dir}/log/hammer/cron-server.log</string>
          </dict>
          </plist>
        XML
        warn Shell.paint("# save to ~/Library/LaunchAgents/#{label}.plist, then:", :gray)
        warn Shell.paint("#   launchctl load ~/Library/LaunchAgents/#{label}.plist", :gray)
      else
        puts <<~UNIT
          [Unit]
          Description=hammer h:cron job server (#{File.basename(@root_dir)})

          [Service]
          ExecStart=#{@hammer_bin} h:cron --port=#{@port}
          WorkingDirectory=#{@root_dir}
          Restart=on-failure

          [Install]
          WantedBy=default.target
        UNIT
        warn Shell.paint('# save to ~/.config/systemd/user/hammer-cron.service, then:', :gray)
        warn Shell.paint('#   systemctl --user enable --now hammer-cron', :gray)
      end
    end

    # ----- snapshots for the web UI ----------------------------------------

    # Plain-value copy of every job, taken under the mutex, so the web
    # thread never renders half-updated state.
    def snapshot
      @mutex.synchronize do
        @jobs.values.map do |j|
          { path: j.path, desc: j.command.brief, cron: j.schedule.source,
            last_run: j.last_run, status: j.status, exit_code: j.exit_code,
            duration: j.duration, running: j.running?,
            next_run: j.schedule.next_run(Time.now, last_run: j.last_run) }
        end
      end
    end

    def job?(path)
      @jobs.key?(path)
    end

    private

    # Refuse to start when the state file points at another live h:cron -
    # two schedulers would double-fire every job. Best-effort (no lock
    # file): kill(0) tells us whether that pid is still alive.
    def ensure_single_instance!
      return unless @saved_pid && @saved_pid != Process.pid
      begin
        Process.kill(0, @saved_pid)
      rescue Errno::ESRCH, Errno::EPERM
        return   # stale pid, fine to start
      end
      raise Hammer::Error, "h:cron already running (pid #{@saved_pid}) - stop it first"
    end

    # Sleep in <=1s slices until the next minute boundary so Ctrl-C is
    # honored within a second. Returns the boundary Time, or nil on stop.
    def wait_for_minute
      target = (Time.now.to_i / 60 + 1) * 60
      while Time.now.to_i < target
        return nil if @stop
        sleep [target - Time.now.to_f, 1].min
      end
      Time.at(target)
    end

    # Due-checks read job state the runner threads mutate - grab the
    # mutex for the read, launch outside it (launch re-locks itself).
    def each_job_snapshot(&block)
      @jobs.values.each(&block)
    end

    # Stop accepting HTTP, then give in-flight runs a short grace period
    # to finish - a mid-backup kill is worse than a late exit. The
    # subprocesses themselves are never signaled.
    def shutdown!
      Shell.say 'shutting down...', :gray
      @web&.stop
      @threads.each { |t| t.join(10) }
      save_state
    end

    def append_line(job, line)
      FileUtils.mkdir_p(@log_dir)
      File.open(log_path(job), 'a') { |f| f.puts(line) }
    end

    def format_time(t)
      t ? t.strftime('%F %T') : 'never'
    end
  end
end

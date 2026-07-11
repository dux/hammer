require_relative 'test_helper'
require 'hammer/cron_server'
require 'hammer/cron_web'
require 'json'
require 'socket'

class CronServerTest < Minitest::Test
  include CaptureIO

  CLI ||= proc do
    task :tick do
      desc 'Tick every minute'
      cron '1m'
      proc { |_| }
    end
    namespace :db do
      task :backup do
        desc 'Nightly backup'
        cron '@daily'
        proc { |_| }
      end
    end
    task :plain do
      desc 'No schedule'
      proc { |_| }
    end
  end

  def build_cli(&block)
    Class.new(Hammer) { instance_eval(&block) }
  end

  # CronServer resolves everything relative to Dir.pwd (Hammer.cli
  # chdir-ed there before dispatch), so tests chdir into a tmpdir.
  def with_server
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        yield Hammer::CronServer.new(build_cli(&CLI), port: 0), dir
      end
    end
  end

  # ----- discovery ------------------------------------------------------

  def test_discovers_cron_tagged_tasks_including_namespaced
    with_server do |server, _|
      assert_equal %w[db:backup tick], server.jobs.keys.sort
    end
  end

  def test_raises_when_no_task_is_scheduled
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        cli = build_cli do
          task :plain do
            proc { |_| }
          end
        end
        err = assert_raises(Hammer::Error) { Hammer::CronServer.new(cli, port: 0) }
        assert_match(/no tasks declare a cron schedule/, err.message)
      end
    end
  end

  def test_file_slug
    with_server do |server, _|
      assert server.log_path(server.jobs['db:backup']).end_with?('log/hammer/db-backup.log')
      assert server.log_path(server.jobs['tick']).end_with?('log/hammer/tick.log')
    end
  end

  # ----- log rotation -----------------------------------------------------

  def test_rotates_past_max_and_keeps_two_files
    with_server do |server, dir|
      job  = server.jobs['tick']
      path = server.log_path(job)
      FileUtils.mkdir_p(File.dirname(path))

      File.write(path, 'a' * (Hammer::CronServer::MAX_LOG_BYTES + 1))
      server.rotate_log(job)
      refute File.exist?(path), 'current log should have rolled away'
      assert File.exist?("#{path}.1")

      # a second oversized log clobbers .1 - never a .2
      File.write(path, 'b' * (Hammer::CronServer::MAX_LOG_BYTES + 1))
      server.rotate_log(job)
      assert_equal 'b', File.read("#{path}.1")[0]
      refute File.exist?("#{path}.2")
    end
  end

  def test_rotation_skips_small_and_missing_logs
    with_server do |server, _|
      job  = server.jobs['tick']
      path = server.log_path(job)
      server.rotate_log(job)   # no file at all - must not raise
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'small')
      server.rotate_log(job)
      assert_equal 'small', File.read(path)
      refute File.exist?("#{path}.1")
    end
  end

  # ----- state file ---------------------------------------------------------

  def test_state_round_trip
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        server = Hammer::CronServer.new(build_cli(&CLI), port: 0)
        job = server.jobs['tick']
        job.last_run  = Time.at(1_783_980_000)
        job.exit_code = 0
        job.status    = 'ok'
        server.save_state

        state_path = File.join(dir, 'tmp/hammer/cron.state.json')
        assert File.exist?(state_path)
        refute File.exist?("#{state_path}.tmp"), 'atomic tmp file must not linger'

        reloaded = Hammer::CronServer.new(build_cli(&CLI), port: 0)
        assert_equal Time.at(1_783_980_000), reloaded.jobs['tick'].last_run
        assert_equal 'ok', reloaded.jobs['tick'].status
        assert_nil reloaded.jobs['db:backup'].last_run
      end
    end
  end

  def test_state_tolerates_corrupt_file
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p('tmp/hammer')
        File.write('tmp/hammer/cron.state.json', 'not json {')
        server = nil
        capture { server = Hammer::CronServer.new(build_cli(&CLI), port: 0) }
        assert_nil server.jobs['tick'].last_run
      end
    end
  end

  def test_state_saves_running_pid
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        server = Hammer::CronServer.new(build_cli(&CLI), port: 0)
        job = server.jobs['tick']
        job.status = 'running'
        job.pid    = 12_345
        server.save_state
        saved = JSON.parse(File.read('tmp/hammer/cron.state.json'))
        assert_equal 12_345, saved['jobs']['tick']['pid']
        # the :starting placeholder must never leak into the file
        job.pid = :starting
        server.save_state
        saved = JSON.parse(File.read('tmp/hammer/cron.state.json'))
        assert_nil saved['jobs']['tick']['pid']
      end
    end
  end

  # Server died mid-run and the subprocess is gone too: the run's exit
  # status is lost, so the job must come back as 'unknown', not stay
  # 'running' forever.
  def test_state_dead_orphan_becomes_unknown
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        dead_pid = Process.spawn('true')
        Process.wait(dead_pid)
        FileUtils.mkdir_p('tmp/hammer')
        File.write('tmp/hammer/cron.state.json', JSON.generate(
          schema: 1, jobs: { 'tick' => { last_run: 123, status: 'running', pid: dead_pid } }
        ))
        server = Hammer::CronServer.new(build_cli(&CLI), port: 0)
        job = server.jobs['tick']
        assert_equal 'unknown', job.status
        refute job.running?
      end
    end
  end

  # Server died mid-run but the subprocess survived as an orphan: it
  # must come back as running (so the overlap guard keeps skipping).
  def test_state_live_orphan_restored_as_running
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        live_pid = Process.spawn('sleep', '30')
        begin
          FileUtils.mkdir_p('tmp/hammer')
          File.write('tmp/hammer/cron.state.json', JSON.generate(
            schema: 1, jobs: { 'tick' => { last_run: 123, status: 'running', pid: live_pid } }
          ))
          server = Hammer::CronServer.new(build_cli(&CLI), port: 0)
          job = server.jobs['tick']
          assert_equal 'running', job.status
          assert_equal live_pid, job.pid
          assert job.running?
        ensure
          Process.kill('KILL', live_pid)
          Process.wait(live_pid)
        end
      end
    end
  end

  def test_state_prunes_undeclared_jobs_on_save
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p('tmp/hammer')
        File.write('tmp/hammer/cron.state.json', JSON.generate(
          schema: 1, jobs: { 'gone:task' => { last_run: 123 }, 'tick' => { last_run: 456 } }
        ))
        server = Hammer::CronServer.new(build_cli(&CLI), port: 0)
        server.save_state
        saved = JSON.parse(File.read('tmp/hammer/cron.state.json'))
        assert saved['jobs'].key?('tick')
        refute saved['jobs'].key?('gone:task')
      end
    end
  end

  # ----- service units -------------------------------------------------------

  def test_service_unit_contains_paths_and_port
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        server = Hammer::CronServer.new(build_cli(&CLI), port: 4267)
        out, = capture { server.print_service_unit }
        assert_includes out, 'h:cron'
        assert_includes out, '--port=4267'
        assert_includes out, File.realpath(dir)   # WorkingDirectory
      end
    end
  end

  # ----- startup summary ------------------------------------------------------

  def test_startup_summary_lists_jobs_and_next_runs
    with_server do |server, _|
      out, = capture { server.print_startup_summary }
      assert_includes out, 'tick'
      assert_includes out, 'db:backup'
      assert_includes out, '@daily'
      assert_includes out, 'never'
    end
  end

  # ----- web ui -----------------------------------------------------------------

  def with_web
    with_server do |server, dir|
      web = Hammer::CronWeb.new(server, port: 0).start
      begin
        yield server, web, web.bound_port, dir
      ensure
        web.stop
      end
    end
  end

  def request(port, raw)
    TCPSocket.open('127.0.0.1', port) do |s|
      s.write(raw)
      s.read
    end
  end

  def test_web_index_lists_jobs
    with_web do |_, _, port, _|
      res = request(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '200 OK'
      assert_includes res, 'db:backup'
      assert_includes res, '@daily'
      assert_includes res, 'run now'
    end
  end

  def test_web_job_page_shows_log
    with_web do |server, _, port, _|
      job  = server.jobs['tick']
      FileUtils.mkdir_p(File.dirname(server.log_path(job)))
      File.write(server.log_path(job), "hello from tick & friends\n")
      res = request(port, "GET /job/tick HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '200 OK'
      assert_includes res, 'hello from tick &amp; friends'   # escaped
    end
  end

  def test_web_unknown_paths_404_and_escape
    with_web do |_, _, port, _|
      res = request(port, "GET /job/%3Cscript%3E HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '404 Not Found'
      assert_includes res, '&lt;script&gt;'
      refute_includes res, '<script>'

      res = request(port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '404 Not Found'
    end
  end

  def test_web_json_status
    with_web do |_, _, port, _|
      res  = request(port, "GET /json HTTP/1.1\r\nHost: x\r\n\r\n")
      body = res.split("\r\n\r\n", 2).last
      jobs = JSON.parse(body)
      assert_equal %w[db:backup tick], jobs.map { |j| j['path'] }.sort
      assert(jobs.all? { |j| j.key?('next_run') })
    end
  end

  def test_web_run_now_unknown_job_404s
    with_web do |_, _, port, _|
      res = request(port, "POST /job/nope/run HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
      assert_includes res, '404 Not Found'
    end
  end

  # ----- basic auth (--pass) ------------------------------------------------

  def with_protected_web(pass)
    with_server do |server, dir|
      web = Hammer::CronWeb.new(server, port: 0, pass: pass).start
      begin
        yield server, web, web.bound_port, dir
      ensure
        web.stop
      end
    end
  end

  def basic(user_pass)
    "Authorization: Basic #{[user_pass].pack('m0')}"
  end

  def test_web_pass_rejects_missing_and_wrong_credentials
    with_protected_web('secret') do |_, _, port, _|
      res = request(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '401 Unauthorized'
      assert_includes res, 'WWW-Authenticate: Basic realm="h:cron"'
      refute_includes res, 'run now'

      res = request(port, "GET / HTTP/1.1\r\nHost: x\r\n#{basic('user:wrong')}\r\n\r\n")
      assert_includes res, '401 Unauthorized'

      # run-now must be locked down too, not just the pages
      res = request(port, "POST /job/tick/run HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
      assert_includes res, '401 Unauthorized'
    end
  end

  def test_web_pass_accepts_correct_password_any_username
    with_protected_web('secret') do |_, _, port, _|
      res = request(port, "GET / HTTP/1.1\r\nHost: x\r\n#{basic('anyone:secret')}\r\n\r\n")
      assert_includes res, '200 OK'
      assert_includes res, 'db:backup'

      res = request(port, "GET /json HTTP/1.1\r\nHost: x\r\n#{basic(':secret')}\r\n\r\n")
      assert_includes res, '200 OK'
    end
  end

  def test_web_empty_pass_disables_auth
    with_protected_web('') do |_, _, port, _|
      res = request(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert_includes res, '200 OK'
    end
  end

  def test_service_unit_carries_pass
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        server = Hammer::CronServer.new(build_cli(&CLI), port: 4267, pass: 'secret')
        out, = capture { server.print_service_unit }
        assert_includes out, '--pass=secret'
      end
    end
  end

  def test_launchd_service_unit_xml_escapes_dynamic_values
    Dir.mktmpdir(['hammer&', '<root>']) do |dir|
      Dir.chdir(dir) do
        server = Hammer::CronServer.new(build_cli(&CLI), port: 4267,
                                        pass: 'secret&<value>')
        out = server.send(:launchd_service_unit)
        assert_includes out, '--pass=secret&amp;&lt;value&gt;'
        assert_includes out, File.realpath(dir).gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        refute_includes out, '--pass=secret&<value>'
      end
    end
  end

  def test_systemd_service_unit_quotes_dynamic_arguments
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        password = 'long secret%#"\\${HOME}'
        server = Hammer::CronServer.new(build_cli(&CLI), port: 4267, pass: password)
        out = server.send(:systemd_service_unit)
        assert_includes out, '"--pass=long secret%%#\"\\\\$${HOME}"'
        refute_includes out, ' --pass=long secret'
      end
    end
  end
end

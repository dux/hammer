require 'socket'
require 'cgi'
require 'json'

class Hammer
  # Localhost web UI for Hammer::CronServer. Hand-rolled HTTP on stdlib
  # TCPServer - the gem has no runtime dependencies and the protocol
  # surface needed here is tiny: parse the request line, drain headers,
  # route on verb+path, answer with Connection: close. No keep-alive, no
  # chunked encoding, one short-lived thread per request so a slow
  # client cannot block the scheduler or other viewers.
  #
  # Routes:
  #   GET  /               jobs table (schedule, last/next run, status)
  #   GET  /job/<path>     log viewer; ?file=1 shows the rotated log
  #   POST /job/<path>/run trigger a manual run, redirect back (303)
  #   GET  /json           live status as JSON, for scripting
  class CronWeb
    REFRESH_SECONDS ||= 10
    TAIL_BYTES      ||= 65_536   # log viewer shows at most the last 64 KB

    def initialize(server, port:)
      @server = server
      @port   = port
    end

    # Actual bound port - differs from the requested one only when the
    # caller asked for port 0 (tests grab a free ephemeral port that way).
    def bound_port
      @tcp&.addr&.fetch(1)
    end

    # Bind 127.0.0.1 only - the UI can trigger task runs, it must never
    # listen on a public interface. Returns self so the caller can hold
    # the instance for #stop.
    def start
      @tcp = TCPServer.new('127.0.0.1', @port)
      @thread = Thread.new do
        loop do
          sock = begin
            @tcp.accept
          rescue IOError, Errno::EBADF
            break   # #stop closed the listener
          end
          Thread.new(sock) do |s|
            begin
              handle(s)
            rescue StandardError
              nil   # a broken client must not take the UI down
            ensure
              s.close rescue nil
            end
          end
        end
      end
      self
    rescue Errno::EADDRINUSE
      raise Hammer::Error, "h:cron web ui: port #{@port} is taken - pick another with --port"
    end

    # Closing the listener pops the accept loop out with IOError.
    def stop
      @tcp&.close
      @thread&.join(2)
    end

    private

    # Minimal HTTP: request line + headers, drain any Content-Length body
    # (our POSTs carry none we care about), then route.
    def handle(sock)
      line = sock.gets or return
      verb, target, = line.split(' ', 3)
      length = 0
      while (h = sock.gets) && h.strip != ''
        length = h.split(':', 2).last.to_i if h =~ /\Acontent-length:/i
      end
      sock.read(length) if length > 0

      path, query = target.to_s.split('?', 2)
      route(sock, verb, CGI.unescape(path.to_s), query.to_s)
    end

    def route(sock, verb, path, query)
      case
      when verb == 'GET' && path == '/'
        respond(sock, 200, layout('jobs', index_html))
      when verb == 'GET' && path == '/json'
        respond(sock, 200, JSON.pretty_generate(json_status), type: 'application/json')
      when verb == 'POST' && path =~ %r{\A/job/(.+)/run\z}
        job_path = Regexp.last_match(1)
        if @server.run_now(job_path)
          redirect(sock, "/job/#{CGI.escape(job_path)}")
        else
          respond(sock, 404, layout('not found', "<p>unknown job #{h(job_path)}</p>"))
        end
      when verb == 'GET' && path =~ %r{\A/job/(.+)\z}
        job_path = Regexp.last_match(1)
        if @server.job?(job_path)
          respond(sock, 200, layout(job_path, job_html(job_path, rotated: query == 'file=1')))
        else
          respond(sock, 404, layout('not found', "<p>unknown job #{h(job_path)}</p>"))
        end
      else
        respond(sock, 404, layout('not found', '<p>404</p>'))
      end
    end

    # ----- responses -------------------------------------------------------

    def respond(sock, status, body, type: 'text/html; charset=utf-8')
      text = { 200 => 'OK', 303 => 'See Other', 404 => 'Not Found' }[status] || 'OK'
      sock.write "HTTP/1.1 #{status} #{text}\r\n" \
                 "Content-Type: #{type}\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n"
      sock.write body
    end

    # Post-redirect-get: the browser lands back on a plain GET, so a
    # refresh never re-triggers the run.
    def redirect(sock, location)
      sock.write "HTTP/1.1 303 See Other\r\n" \
                 "Location: #{location}\r\n" \
                 "Content-Length: 0\r\n" \
                 "Connection: close\r\n\r\n"
    end

    # ----- views -----------------------------------------------------------

    def index_html
      rows = @server.snapshot.map do |j|
        badge = status_badge(j)
        <<~ROW
          <tr>
            <td><a href="/job/#{CGI.escape(j[:path])}">#{h(j[:path])}</a></td>
            <td><code>#{h(j[:cron])}</code></td>
            <td>#{h(fmt_time(j[:last_run]))}</td>
            <td>#{badge}</td>
            <td>#{h(fmt_time(j[:next_run]))}</td>
            <td>
              <form method="post" action="/job/#{CGI.escape(j[:path])}/run">
                <button#{j[:running] ? ' disabled' : ''}>run now</button>
              </form>
            </td>
          </tr>
        ROW
      end
      <<~HTML
        <table>
          <tr><th>task</th><th>schedule</th><th>last run</th><th>status</th><th>next run</th><th></th></tr>
          #{rows.join}
        </table>
      HTML
    end

    def job_html(path, rotated: false)
      job  = @server.snapshot.find { |j| j[:path] == path }
      file = log_file(path, rotated: rotated)
      log  = tail_file(file)
      <<~HTML
        <p><a href="/">&larr; all jobs</a></p>
        <h2>#{h(path)}</h2>
        <p>
          <code>#{h(job[:cron])}</code> &middot;
          #{status_badge(job)} &middot;
          last run #{h(fmt_time(job[:last_run]))} &middot;
          next run #{h(fmt_time(job[:next_run]))}
          #{job[:duration] ? "&middot; took #{format('%.1f', job[:duration])}s" : ''}
        </p>
        <form method="post" action="/job/#{CGI.escape(path)}/run">
          <button#{job[:running] ? ' disabled' : ''}>run now</button>
        </form>
        <p class="files">
          #{rotated ? "<a href=\"/job/#{CGI.escape(path)}\">current log</a>" : '<b>current log</b>'} |
          #{rotated ? '<b>rotated log</b>' : "<a href=\"/job/#{CGI.escape(path)}?file=1\">rotated log</a>"}
        </p>
        <pre>#{h(log)}</pre>
      HTML
    end

    def layout(title, body)
      <<~HTML
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="refresh" content="#{REFRESH_SECONDS}">
          <title>h:cron - #{h(title)}</title>
          <style>
            body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                   margin: 2rem auto; max-width: 60rem; padding: 0 1rem; color: #222; }
            h1 a { color: inherit; text-decoration: none; }
            table { border-collapse: collapse; width: 100%; }
            th, td { text-align: left; padding: .4rem .8rem; border-bottom: 1px solid #ddd; }
            th { color: #888; font-weight: 600; }
            code { background: #f4f4f4; padding: .1rem .3rem; border-radius: 3px; }
            pre { background: #1a1a1a; color: #ddd; padding: 1rem; border-radius: 6px;
                  overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
            button { cursor: pointer; }
            .ok      { color: #2a7d2a; }
            .failed, .error { color: #c02626; }
            .running { color: #b8860b; }
            .never   { color: #888; }
            .files   { color: #888; }
            footer   { color: #aaa; margin-top: 2rem; font-size: 12px; }
            @media (prefers-color-scheme: dark) {
              body { background: #111; color: #ccc; }
              th, td { border-color: #333; }
              code { background: #222; }
            }
          </style>
        </head>
        <body>
          <h1><a href="/">h:cron</a></h1>
          #{body}
          <footer>hammer #{Hammer::VERSION} &middot; #{h(@server.root_dir)} &middot; refreshes every #{REFRESH_SECONDS}s</footer>
        </body>
        </html>
      HTML
    end

    def status_badge(j)
      label = j[:running] ? 'running' : (j[:status] || 'never ran')
      css   = j[:running] ? 'running' : (j[:status] || 'never')
      extra = !j[:running] && j[:exit_code] ? " (exit #{j[:exit_code]})" : ''
      "<span class=\"#{h(css)}\">#{h(label)}#{h(extra)}</span>"
    end

    def json_status
      @server.snapshot.map do |j|
        j.merge(last_run: j[:last_run]&.to_i, next_run: j[:next_run]&.to_i)
      end
    end

    # ----- helpers ----------------------------------------------------------

    def log_file(path, rotated: false)
      slug = path.tr(':', '-').gsub(/[^\w.-]/, '-')
      file = File.join(@server.root_dir, 'log/hammer', "#{slug}.log")
      rotated ? "#{file}.1" : file
    end

    # Last TAIL_BYTES of the file - enough for a viewer, cheap even when
    # the log sits right under the 1 MB rotation cap.
    def tail_file(file)
      size = File.size(file)
      File.open(file) do |f|
        f.seek([size - TAIL_BYTES, 0].max)
        data = f.read.to_s
        size > TAIL_BYTES ? "... (truncated)\n#{data}" : data
      end
    rescue Errno::ENOENT
      '(no log yet)'
    end

    def fmt_time(t)
      t ? t.strftime('%F %T') : 'never'
    end

    def h(text)
      CGI.escapeHTML(text.to_s)
    end
  end
end

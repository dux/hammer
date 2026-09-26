require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'

class ShebangTest < Minitest::Test
  include CaptureIO

  # Write a shebang script under `dir`, chmod +x, return its path.
  def write_script(dir, name, body, shebang: '#!/usr/bin/env hammer')
    path = File.join(dir, name)
    File.write(path, "#{shebang}\n#{body}")
    File.chmod(0755, path)
    path
  end

  def test_shebang_script_dispatches_task
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'shebcli', <<~'RUBY')
        task :hello do
          proc { |_| say 'hello from shebang' }
        end
      RUBY
      out, = capture { Hammer.cli([script, 'hello']) }
      assert_includes out, 'hello from shebang'
    end
  end

  def test_program_name_is_script_basename
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'shebcli', <<~'RUBY')
        task :hello do
          desc 'say hi'
          proc { |_| say 'hi' }
        end
      RUBY
      out, = capture { Hammer.cli([script, '--help']) }
      assert_includes out, 'Usage: shebcli'
      refute_includes out, 'Usage: hammer'
    end
  end

  def test_program_name_strips_rb_extension
    # ~/bin/llm execs recipes/llm.rb; the shebang path is the .rb file,
    # but the CLI the user typed is `llm`.
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'llm.rb', <<~'RUBY')
        task :usage do
          desc 'show usage'
          proc { |_| say 'ok' }
        end
      RUBY
      out, err = capture { Hammer.cli([script, 'usage']) }
      refute_includes err, 'llm.rb'
      assert_includes err, '> llm usage'
      help, = capture { Hammer.cli([script, '--help']) }
      assert_includes help, 'Usage: llm'
      refute_includes help, 'Usage: llm.rb'
    end
  end

  def test_cwd_is_preserved
    Dir.mktmpdir do |script_dir|
      Dir.mktmpdir do |run_dir|
        script = write_script(script_dir, 'pwdcli', <<~'RUBY')
          task :pwd do
            proc { |_| say "PWD_MARKER=#{Dir.pwd}" }
          end
        RUBY
        out = nil
        Dir.chdir(run_dir) do
          out, = capture { Hammer.cli([script, 'pwd']) }
        end
        m = out.match(/PWD_MARKER=(.+)/)
        assert m, "expected PWD_MARKER in output, got: #{out.inspect}"
        # macOS symlinks /tmp -> /private/tmp; compare via realpath.
        assert_equal File.realpath(run_dir), File.realpath(m[1].strip)
      end
    end
  end

  def test_symlink_uses_symlink_basename_in_help
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'real', <<~'RUBY')
        task :hi do
          desc 'say hi'
          proc { |_| say 'hi' }
        end
      RUBY
      link = File.join(dir, 'aliased')
      File.symlink(script, link)
      out, = capture { Hammer.cli([link, '--help']) }
      assert_includes out, 'Usage: aliased'
    end
  end

  def test_non_shebang_file_is_not_hijacked
    # File exists at argv[0] but its first line doesn't reference hammer,
    # so it falls through to normal Hammerfile lookup (which fails here).
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'data.txt'), "not a script\n")
      Dir.chdir(dir) do
        _, err, status = capture_exit { Hammer.cli(['data.txt']) }
        assert_equal 1, status
        assert_includes err, 'no Hammerfile found'
      end
    end
  end

  def test_shebang_without_hammer_keyword_is_not_hijacked
    # Generic `#!/usr/bin/env ruby` script - shebang present but not ours.
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'ruby-script')
      File.write(path, "#!/usr/bin/env ruby\nputs 'hi'\n")
      File.chmod(0755, path)
      Dir.chdir(dir) do
        _, err, status = capture_exit { Hammer.cli([path]) }
        assert_equal 1, status
        assert_includes err, 'no Hammerfile found'
      end
    end
  end

  def test_leading_flag_skips_detection
    # `--help` must never be probed as a file path.
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        out, = capture { Hammer.cli(['--help']) }
        assert_includes out, 'Usage:'
      end
    end
  end

  def test_no_core_builtins_registered
    # Shebang scripts are self-contained - hammer's own update/agents/version
    # tasks should not appear in the script's --help.
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'shebcli', <<~'RUBY')
        task :hello do
          desc 'say hi'
          proc { |_| say 'hi' }
        end
      RUBY
      out, = capture { Hammer.cli([script, '--help']) }
      refute_includes out, 'shebcli agents'
      refute_includes out, 'shebcli update'
      refute_includes out, 'shebcli version'
      refute_includes out, 'shebcli recipes'
    end
  end

  def test_namespaces_and_options_work
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'shebcli', <<~'RUBY')
        namespace :sub do
          task :greet do
            desc 'greet someone'
            opt :loud, type: :boolean, alias: :l
            proc do |opts|
              msg = "hi #{opts[:args].first || 'world'}"
              msg = msg.upcase if opts[:loud]
              say msg
            end
          end
        end
      RUBY
      out, = capture { Hammer.cli([script, 'sub:greet', 'dino', '--loud']) }
      assert_includes out, 'HI DINO'
    end
  end

  def test_direct_shebang_path_also_detected
    # Direct shebang `#!/abs/path/to/hammer` (no env wrapper). Detection
    # only needs `#!` + the word `hammer` on line one.
    Dir.mktmpdir do |dir|
      script = write_script(dir, 'directcli', <<~'RUBY', shebang: '#!/opt/local/bin/hammer')
        task :hi do
          proc { |_| say 'direct shebang ok' }
        end
      RUBY
      out, = capture { Hammer.cli([script, 'hi']) }
      assert_includes out, 'direct shebang ok'
    end
  end
end

require_relative 'test_helper'
require 'stringio'

# End-to-end through the recipe: each test runs `llm todo:*` in a scratch
# directory with $stdin swapped, the way a shell pipe would feed it.
class LlmTodoTest < Minitest::Test
  include CaptureIO

  LLM = File.expand_path('../recipes/llm.rb', __dir__)

  def setup
    @dir = Dir.mktmpdir('llm-todo')
    @cwd = Dir.pwd
    @stdin_was = $stdin
    Dir.chdir @dir
  end

  def teardown
    Dir.chdir @cwd
    $stdin = @stdin_was
    FileUtils.remove_entry @dir
  end

  def todo(*args, stdin: nil)
    $stdin = stdin ? StringIO.new(stdin) : StringIO.new('')
    capture { Hammer.cli([LLM, *args]) }
  end

  def tasks
    File.read(File.join(@dir, 'LLM_TODO.local.md')).scan(/^\* (.*)$/).flatten
  end

  def test_add_argument_is_one_task
    todo('todo:add', 'fix login')
    assert_equal ['fix login'], tasks
  end

  def test_bulk_without_bullets_is_one_task_per_line
    todo('todo:add', stdin: "first\nsecond\n\nthird\n")
    assert_equal %w[first second third], tasks
  end

  def test_bulk_with_bullets_keeps_continuation_lines
    todo('todo:add', stdin: "* one\n  more of one\n* two\n")
    assert_equal ['one', 'two'], tasks
    assert_includes File.read('LLM_TODO.local.md'), "* one\n  more of one\n"
  end

  def test_list_does_not_read_stdin
    todo('todo:add', 'x')
    require 'socket'
    ours, theirs = UNIXSocket.pair
    $stdin = ours
    out, = capture { Hammer.cli([LLM, 'todo:list']) }
    assert_includes out, '1 todo'
  ensure
    ours&.close
    theirs&.close
  end
end

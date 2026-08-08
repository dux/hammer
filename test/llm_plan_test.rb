# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

require_relative 'test_helper'
require_relative '../recipes/lib/llm/plan'

class LlmPlanTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('llm-plan')
    FileUtils.mkdir_p File.join(@root, 'tmp')
  end

  def teardown
    FileUtils.remove_entry @root
  end

  # --- validation ---------------------------------------------------------

  def test_rejects_unknown_op
    assert_error(/unknown op/) { bundle(files: [{ 'path' => './a.rb', 'op' => 'touch' }]) }
  end

  def test_rejects_absolute_path
    assert_error(/absolute paths/) { bundle(files: [{ 'path' => '/etc/hosts', 'op' => 'create', 'content' => 'x' }]) }
  end

  def test_rejects_path_outside_the_tree
    assert_error(/escapes the working tree/) do
      bundle(files: [{ 'path' => '../outside.rb', 'op' => 'create', 'content' => 'x' }])
    end
  end

  def test_rejects_create_without_content
    assert_error(/create needs content/) { bundle(files: [{ 'path' => './a.rb', 'op' => 'create' }]) }
  end

  def test_rejects_change_without_sha1
    write 'a.rb', "x\n"
    assert_error(/needs a sha1/) do
      bundle(files: [{ 'path' => './a.rb', 'op' => 'change', 'hunks' => [hunk('x', 'y')] }])
    end
  end

  def test_rejects_change_without_hunks
    write 'a.rb', "x\n"
    assert_error(/needs at least one hunk/) { bundle(files: [change('./a.rb', [])]) }
  end

  def test_rejects_noop_hunk
    write 'a.rb', "x\n"
    assert_error(/identical/) { bundle(files: [change('./a.rb', [hunk('x', 'x')])]) }
  end

  def test_rejects_duplicate_paths
    assert_error(/duplicate path/) do
      bundle(files: [{ 'path' => './a.rb', 'op' => 'create', 'content' => 'x' },
                     { 'path' => './a.rb', 'op' => 'create', 'content' => 'y' }])
    end
  end

  def test_rejects_malformed_json
    path = File.join(@root, 'tmp', 'plan-broken.json')
    File.write path, '{ not json'
    assert_error(/not valid json/) { LlmPlan::Bundle.new(path, root: @root) }
  end

  # --- clean apply --------------------------------------------------------

  def test_applies_create_change_and_delete
    write 'keep.rb', "old line\n"
    write 'gone.rb', "bye\n"

    outcome = run_apply(mixed_bundle)

    assert_equal 3, outcome.applied.size
    assert outcome.clean?
    assert_equal 0, outcome.exit_code
    assert_equal "new file\n", read('new.rb')
    assert_equal "new line\n", read('keep.rb')
    refute File.exist?(File.join(@root, 'gone.rb'))
  end

  def test_backs_up_and_writes_the_commit_message
    write 'keep.rb', "old line\n"
    write 'gone.rb', "bye\n"

    bundle = mixed_bundle
    run_apply bundle

    assert_equal "old line\n", File.read(File.join(bundle.backup_dir, 'keep.rb'))
    assert_equal "bye\n",      File.read(File.join(bundle.backup_dir, 'gone.rb'))
    assert_equal "subject\n\nbody\n", File.read(bundle.message_path)
  end

  def test_adds_a_trailing_newline_to_created_files
    run_apply bundle(files: [{ 'path' => './a.rb', 'op' => 'create', 'content' => 'no newline' }])

    assert_equal "no newline\n", read('a.rb')
  end

  # --- drift --------------------------------------------------------------

  def test_drifted_file_is_reported_and_the_rest_still_apply
    write 'keep.rb', "old line\n"
    write 'gone.rb', "bye\n"

    bundle = mixed_bundle
    write 'keep.rb', "someone else got here\n"

    outcome = run_apply(bundle)

    assert_equal 2, outcome.applied.size
    assert_equal 1, outcome.drifted.size
    assert_equal './keep.rb', outcome.drifted.first.entry.path
    assert_match(/changed since planning/, outcome.drifted.first.reason)
    assert_equal 10, outcome.exit_code
    assert_equal "someone else got here\n", read('keep.rb')
  end

  def test_drift_report_carries_the_intent_and_wanted_text
    write 'keep.rb', "old line\n"
    bundle = bundle(files: [change('./keep.rb', [hunk('old line', 'new line', intent: 'rename the line')])])
    write 'keep.rb', "drifted\n"

    text = report_text(run_apply(bundle))

    assert_match(/DRIFT \.\/keep\.rb/, text)
    assert_match(/intent: rename the line/, text)
    assert_match(/--- wanted old ---\nold line/, text)
    assert_match(/--- wanted new ---\nnew line/, text)
  end

  def test_missing_file_drifts
    write 'keep.rb', "old line\n"
    bundle = bundle(files: [change('./keep.rb', [hunk('old line', 'new line')])])
    FileUtils.rm_f File.join(@root, 'keep.rb')

    assert_match(/planned file is gone/, run_apply(bundle).drifted.first.reason)
  end

  def test_planned_new_file_that_now_exists_drifts
    bundle = bundle(files: [{ 'path' => './a.rb', 'op' => 'create', 'content' => "mine\n" }])
    write 'a.rb', "someone else's\n"

    outcome = run_apply(bundle)

    assert_match(/exists now/, outcome.drifted.first.reason)
    assert_equal "someone else's\n", read('a.rb')
  end

  def test_symlink_target_drifts_instead_of_being_written_through
    write 'real.rb', "old line\n"
    bundle = bundle(files: [change('./link.rb', [hunk('old line', 'new line')], sha1: sha1('real.rb'))])
    File.symlink File.join(@root, 'real.rb'), File.join(@root, 'link.rb')

    assert_match(/symlink/, run_apply(bundle).drifted.first.reason)
    assert_equal "old line\n", read('real.rb')
  end

  # --- anchors ------------------------------------------------------------

  def test_non_unique_anchor_leaves_the_file_untouched
    write 'a.rb', "dup\ndup\n"
    outcome = run_apply(bundle(files: [change('./a.rb', [hunk('dup', 'one')])]))

    assert_match(/matched 2 times/, outcome.drifted.first.reason)
    assert_equal "dup\ndup\n", read('a.rb')
  end

  def test_one_bad_anchor_rolls_back_the_whole_file
    write 'a.rb', "first\nsecond\n"
    hunks = [hunk('first', 'FIRST'), hunk('nowhere', 'x')]

    outcome = run_apply(bundle(files: [change('./a.rb', hunks)]))

    assert_match(/matched 0 times/, outcome.drifted.first.reason)
    assert_equal "first\nsecond\n", read('a.rb')
  end

  def test_all_flag_replaces_every_occurrence
    write 'a.rb', "dup\ndup\n"
    hunks = [hunk('dup', 'one').merge('all' => true)]

    run_apply bundle(files: [change('./a.rb', hunks)])

    assert_equal "one\none\n", read('a.rb')
  end

  def test_replacement_backreferences_stay_literal
    write 'a.rb', "token\n"
    run_apply bundle(files: [change('./a.rb', [hunk('token', 'a \1 b \& c')])])

    assert_equal "a \\1 b \\& c\n", read('a.rb')
  end

  def test_change_keeps_the_file_mode
    write 'a.rb', "old line\n"
    File.chmod 0o755, File.join(@root, 'a.rb')

    run_apply bundle(files: [change('./a.rb', [hunk('old line', 'new line')])])

    assert_equal '755', format('%o', File.stat(File.join(@root, 'a.rb')).mode & 0o777)
  end

  # --- re-run and revert --------------------------------------------------

  def test_rerunning_an_applied_bundle_is_a_noop
    write 'keep.rb', "old line\n"
    write 'gone.rb', "bye\n"

    bundle = mixed_bundle
    run_apply bundle
    outcome = run_apply(bundle)

    assert_equal 3, outcome.skipped.size
    assert_empty outcome.applied
    assert_empty outcome.drifted
    assert_equal 0, outcome.exit_code
  end

  def test_revert_puts_everything_back
    write 'keep.rb', "old line\n"
    write 'gone.rb', "bye\n"

    bundle = mixed_bundle
    runner = LlmPlan::Runner.new(bundle, root: @root)
    runner.apply
    runner.revert

    refute File.exist?(File.join(@root, 'new.rb'))
    assert_equal "old line\n", read('keep.rb')
    assert_equal "bye\n", read('gone.rb')
  end

  def test_revert_without_a_backup_raises
    assert_error(/no backup/) do
      LlmPlan::Runner.new(bundle(files: [{ 'path' => './a.rb', 'op' => 'create', 'content' => 'x' }]),
                          root: @root).revert
    end
  end

  # --- verify -------------------------------------------------------------

  def test_verify_runs_every_command_in_order
    seen   = []
    runner = LlmPlan::Runner.new(bundle(verify: ['true', 'true'], files: [create_entry]), root: @root)
    result = runner.verify { |cmd| seen << cmd }

    assert result.ok
    assert_equal %w[true true], seen
  end

  def test_verify_stops_at_the_first_failure
    seen   = []
    runner = LlmPlan::Runner.new(bundle(verify: ['true', 'false', 'true'], files: [create_entry]), root: @root)
    result = runner.verify { |cmd| seen << cmd }

    refute result.ok
    assert_equal 'false', result.failed_command
    assert_equal %w[true false], seen
  end

  def test_failing_verify_sets_exit_20
    outcome = run_apply(bundle(verify: ['false'], files: [create_entry]))
    outcome.verify = LlmPlan::Verify.new(false, 'false')

    assert_equal 20, outcome.exit_code
  end

  # --- report -------------------------------------------------------------

  def test_check_only_writes_nothing_and_omits_the_revert_hint
    write 'keep.rb', "old line\n"
    bundle  = bundle(files: [change('./keep.rb', [hunk('old line', 'new line')])])
    outcome = LlmPlan::Runner.new(bundle, root: @root).apply(check_only: true)

    assert_equal 1, outcome.applied.size
    assert_equal "old line\n", read('keep.rb')
    refute File.exist?(bundle.message_path)
    refute_match(/llm plan:revert/, report_text(outcome))
  end

  def test_applied_report_carries_the_revert_hint
    assert_match(/llm plan:revert/, report_text(run_apply(bundle(files: [create_entry]))))
  end

  private

  def assert_error(pattern, &block)
    assert_match pattern, assert_raises(LlmPlan::Error, &block).message
  end

  def path_in(name) = File.join(@root, name)
  def read(name)    = File.read(path_in(name))
  def sha1(name)    = Digest::SHA1.file(path_in(name)).hexdigest

  def write(name, body)
    FileUtils.mkdir_p File.dirname(path_in(name))
    File.write path_in(name), body
  end

  def hunk(old, new, intent: nil)
    { 'old' => old, 'new' => new }.tap { |h| h['intent'] = intent if intent }
  end

  def change(path, hunks, sha1: nil)
    { 'path' => path, 'op' => 'change', 'hunks' => hunks,
      'sha1' => sha1 || self.sha1(path.sub(%r{\A\./}, '')) }
  end

  def create_entry = { 'path' => './new.rb', 'op' => 'create', 'content' => "new file\n" }

  def mixed_bundle
    bundle(files: [create_entry,
                   change('./keep.rb', [hunk('old line', 'new line', intent: 'rename the line')]),
                   { 'path' => './gone.rb', 'op' => 'delete', 'sha1' => sha1('gone.rb') }])
  end

  # Writes a bundle file under <root>/tmp and returns the parsed Bundle.
  def bundle(files:, verify: [], slug: 'test')
    raw  = { 'slug' => slug, 'goal' => 'test goal', 'verify' => verify, 'files' => files,
             'commit' => { 'subject' => 'subject', 'body' => 'body' } }
    path = File.join(@root, 'tmp', "plan-#{slug}.json")
    File.write path, JSON.generate(raw)

    LlmPlan::Bundle.new(path, root: @root)
  end

  def run_apply(bundle) = LlmPlan::Runner.new(bundle, root: @root).apply

  def report_text(outcome)
    LlmPlan::Report.new(outcome).lines.map(&:first).join("\n")
  end
end

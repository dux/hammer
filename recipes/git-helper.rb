#!/usr/bin/env hammer
# desc: work with git (commit, push, pull, rebase, branch, redate, ...)
# executable: chmod +x this file and run directly, or symlink into PATH

desc <<~TXT
  Git helper. Short aliases over common `git` workflows.

  Most subcommands operate on the current branch detected at startup.
  Run from inside a git working tree.
TXT

require 'date'

unless Dir.exist?('.git') || %w[-h --help help].include?(ARGV.first)
  warn "\e[31mNo .git directory\e[0m"
  exit 1
end

Signal.trap('INT') do
  puts ''
  exit
end

if Dir.exist?('.git')
  BRANCH ||= `git rev-parse --abbrev-ref HEAD 2>/dev/null`.chomp
  detected = `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.chomp.split('/').last
  PARENT ||= detected.to_s.empty? ? 'master' : detected
else
  BRANCH ||= ''
  PARENT ||= 'master'
end

helpers do
  private

  def remote_host
    `git remote -v | grep origin`.split(/[:\s]/)[1].to_s
  end

  def origin_path
    `git remote -v | grep origin`.split(/[:\s]/)[2].to_s.sub('.git', '')
  end

  def remote_url
    remote_host.include?('gitlab') ? "https://gitlab.com/#{origin_path}" : "https://github.com/#{origin_path}"
  end

  def remote_page_url
    remote_host.include?('gitlab') ? "#{remote_url}/-/tree/#{BRANCH}" : "#{remote_url}/tree/#{BRANCH}"
  end

  def remote_pr_url
    if remote_host.include?('gitlab')
      "#{remote_url}/-/merge_requests/new?merge_request[source_branch]=#{BRANCH}"
    else
      "#{remote_url}/pull/new/#{BRANCH}"
    end
  end

  def remote_compare_url
    remote_host.include?('gitlab') ? "#{remote_url}/-/compare/#{PARENT}...#{BRANCH}" : "#{remote_url}/compare/#{BRANCH}"
  end

  def changed_files
    `git diff --name-only #{PARENT}..#{BRANCH}`.split($/).select { |f| File.exist?(f) }
  end

  def local_branches
    `git branch`.split($/).map { |b| b.sub(/^[\s*]+/, '') }.reject(&:empty?)
  end

  def open_in_browser(url)
    run "open '#{url}'"
  end

  def bump_version
    return unless BRANCH == 'master' && File.exist?('./.version')
    old = File.read('./.version').gsub(/\s/, '')
    parts = old.split('.')
    parts.push(parts.pop.to_i + 1)
    new = parts.join('.')
    say "Version: #{old} -> #{new.color(:yellow)}"
    File.write('./.version', new)
    run 'git add .version'
    new
  end

  def run(command, returnable = false)
    say '' if @ran_once
    @ran_once = true
    say command, :gray
    if returnable
      `#{command}`.chomp
    else
      system "#{command} 2>&1"
    end
  end

  def pick(question, items)
    items = items.chomp.split($/) if items.is_a?(String)
    items = items.map { |i| i.to_s.sub(/^[\s*]+/, '') }.reject(&:empty?).uniq.sort
    return if items.empty?
    idx = choose(question, items)
    idx ? items[idx] : nil
  end

  def do_commit
    run 'git add .'

    status_text = `git status`.chomp
    if status_text.include?('nothing to commit')
      say status_text, :yellow
      exit
    end

    conflicted = `git grep '<<<<<<<'`.chomp.split($/).reject { |f| f.include?('Binary') }
    unless conflicted.empty?
      say 'Resolve merge first in:'
      puts conflicted
      exit
    end

    rubocop_modified if File.exist?('.rubocop.yml')

    say 'Modified files:'
    say `git status`.split("\n").drop(4).map { |el| el.sub(/^\t/, '') }.join("\n"), :yellow
    say '---'
    say 'Last 3 commits'
    puts `git log -3 --reverse --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit`
    orig_files = `find ./app -name '*.orig' -o -name '*_LOCAL_*' -o -name '*_BACKUP_*' -o -name '*_BASE_*' -o -name '*_REMOTE_*' 2>/dev/null | grep -v '/tmp/'`
    unless orig_files.strip.empty?
      say '---'
      say 'orig tmp git merge files'
      say orig_files, :red
    end
    say '---'

    loop do
      print "Message [#{BRANCH.color(:blue)}]: "
      message = $stdin.gets.to_s.chomp

      if message.empty?
        run 'git reset --mixed'
        exit
      elsif message.length < 1
        say 'Please add better commit message, min length 1 chars', :red
        next
      else
        bump_version
        system('git', 'commit', '-m', message)
        break
      end
    end
  end

  def rubocop_modified
    files = `git status -s`.chomp.split(/\s+/).select { |it| it.include?('.') }
    files = files.select { |it| it.end_with?('.rb') && File.exist?(it) }
    files -= ['db/schema.rb']
    return if files.empty?
    say 'Rubocop check on:'
    puts files
    system "rubocop #{files.join(' ')}"
    exit unless yes?('Continue?')
  end

  def do_redate(redate_to, commit = nil)
    head_date = DateTime.parse(`git log -1 --date=format:"%Y-%m-%dT%T" --format="%ad"`.chomp)

    if redate_to
      if commit
        head_date = DateTime.parse(`git log -1 #{commit} --date=format:"%Y-%m-%dT%T" --format="%ad"`.chomp)
        date = DateTime.parse(redate_to)
      elsif redate_to.include?(':')
        date = DateTime.parse(redate_to)
      elsif redate_to.start_with?('+', '-')
        head_date = DateTime.parse(`git log -2 --date=format:"%Y-%m-%dT%T" --format="%ad"`.chomp.split($/).last)
        direction = redate_to[0]
        hours = redate_to[1..].to_i + rand
        hours = -hours if direction == '-'
        date = head_date + (hours / 24.0)
      else
        error 'Wrong date format'
      end

      commit ||= `git rev-parse HEAD`.chomp
      run %[GIT_COMMITTER_DATE="#{date}" git commit --amend --date="#{date}" -C #{commit}]
      say "Redated from: #{head_date}"
      say "Redated to  : #{date}"
      return
    end

    say 'Last git date:'
    say "  #{head_date.strftime('%A').ljust(10)} - #{head_date}"
    if head_date.wday.positive?
      head_date -= head_date.wday + 1
      say "  #{head_date.strftime('%A').ljust(10)} - #{head_date}"
    end
    say '---'
    say "redate #{head_date} <commit>  # reset specific commit"
    say "redate #{head_date}           # set latest commit to date"
    say 'redate +2                     # shift last commit ~2 hours later'
  end
end

# ---- branch / status --------------------------------------------------

task :status do
  desc 'git status'
  alt :s
  proc { run 'git status -u' }
end

task :branch do
  desc 'Show current branch'
  alt :b
  proc { print BRANCH }
end

task :parent do
  desc "Show parent branch (#{PARENT})"
  proc { print PARENT }
end

task :head do
  desc 'last commit hash + subject'
  proc { run 'git log -1 --pretty=format:"%H %s"' }
end

# ---- sync / push / pull -----------------------------------------------

task :sync do
  desc 'rebase + push + status'
  proc do |_|
    hammer :rebase
    hammer :push
    hammer :status
  end
end

task :pp do
  desc 'Pull & Push'
  proc do |_|
    hammer :pull
    hammer :push
  end
end

task :push do
  desc 'git push origin [current branch]'
  opt :force, type: :boolean, alias: :f, desc: 'use --force-with-lease'
  example 'push'
  example 'push --force'
  example 'push -f'
  proc do |opts|
    flag = opts[:force] ? '--force-with-lease' : ''
    run "git branch -u origin/#{BRANCH}"
    run "git push origin #{BRANCH} #{flag}".rstrip
  end
end

task :pull do
  desc 'git pull origin [current branch] --rebase'
  proc do |_|
    active = `git status --porcelain` =~ /\w/
    run 'git stash push --include-untracked -m "Auto stash before pull" > /dev/null' if active
    run "git pull origin #{BRANCH} --rebase"
    run 'git stash pop > /dev/null' if active
  end
end

task :rebase do
  desc 'fetch + rebase on origin/[current branch]'
  proc do |opts|
    branch = opts[:args].first || BRANCH
    run 'git fetch --all'
    run "git rebase origin/#{branch}"
  end
end

# ---- commit / amend / fixup -------------------------------------------

task :commit do
  desc 'add, message, rubocop and other checks'
  alt :c
  proc { do_commit }
end

task :amend do
  desc 'append staged changes to last commit'
  alt :ammend
  proc { run 'git -c core.hooksPath=/dev/null commit --amend --no-edit' }
end

task :fixup do
  desc 'append code to fixup of last commit'
  proc do |_|
    hash, message = `git log -1 --format="%H %s"`.chomp.split(' ', 2)
    next unless yes?("Fixup on: #{message}")
    run 'git add .'
    run "git commit --fixup #{hash}"
  end
end

# ---- diff / file picking ----------------------------------------------

task :diff do
  desc 'Show diff for one file ("diff all" for all)'
  proc do |opts|
    arg = opts[:args].first
    if arg
      arg = '' if arg == 'all'
      run "git diff #{PARENT}..#{BRANCH} #{arg}".strip
    else
      file = pick('Select file to show ("diff all" for all)', changed_files)
      run "git diff #{PARENT}..#{BRANCH} #{file}" if file
    end
  end
end

task :fhistory do
  desc 'show file history, via gitk'
  proc do |opts|
    file = opts[:args].first || pick('Select file to show', changed_files)
    next unless file
    run "gitk #{file}"
  end
end

task :restore do
  desc "restore single file to #{PARENT}"
  proc do |opts|
    file = opts[:args].first || pick('Select file to restore', changed_files)
    next unless file
    run "git checkout origin/#{PARENT} #{file}"
  end
end

# ---- stash / branch management ----------------------------------------

task :stash do
  desc 'stash tracked and untracked'
  proc { run 'git stash push --include-untracked -m "g stash" > /dev/null' }
end

task :merge do
  desc 'squash-merge current branch into the given branch'
  example 'merge main'
  proc do |opts|
    branch = opts[:args].first or error 'specify branch'
    error 'You must be in a feature branch to squash-merge' if %w[develop main master].include?(BRANCH)
    run "git checkout #{branch}"
    run "git merge --squash #{BRANCH}"
    say.yellow "next (now on #{branch}):"
    say.yellow '  git commit -m "<your_commit_message>"'
    say.yellow "  g push --force      # pushes #{branch}"
  end
end

task :new do
  desc "create new branch from #{PARENT}"
  example 'new feature-x'
  proc do |opts|
    name = opts[:args].first or error 'specify branch name'
    run "git checkout #{PARENT}"
    run 'git pull'
    run "git checkout -b #{name}"
  end
end

task :ch do
  desc 'change branch (interactive picker or by name part)'
  example 'ch'
  example 'ch feature'
  proc do |opts|
    name_part = opts[:args].first
    branches  = `git branch`.chomp.split("\n")
                            .map { |b| b.sub(/^[\s*]+/, '') }
                            .reject { |b| b.include?('backup') || b.empty? }
    branch = if name_part
               branches.find { |b| b.include?(name_part) } or error "no branch matching #{name_part.inspect}"
             else
               error 'working tree not clean - stash or commit first' unless `git status`.include?('working tree clean')
               pick('Switch to branch: ', branches)
             end
    next unless branch
    run 'git fetch origin'
    run "git checkout #{branch}"
    run "git pull origin #{branch} --rebase"
  end
end

task :swap do
  desc 'swap current branch name with another branch'
  proc do |opts|
    branch = opts[:args].first || pick('Switch branch to swap: ', local_branches - [BRANCH])
    next unless branch
    next unless yes?("Swap #{BRANCH} and #{branch}")
    run "git branch -m #{BRANCH}-tmp"
    run "git branch -m #{branch} #{BRANCH}"
    run "git branch -m #{BRANCH}-tmp #{branch}"
    run "git push origin #{branch} --force-with-lease" if yes?('Push branch?')
  end
end

task :delete do
  desc 'delete local branch (interactive)'
  proc do |_|
    branch = pick('Select a branch to DELETE', local_branches - [BRANCH])
    next unless branch
    next unless yes?("Delete branch #{branch}")
    run "git branch -D #{branch}"
  end
end

task :prune do
  desc 'delete local branches gone on remote'
  proc do |_|
    list = `git branch -vv | grep ': gone]' | awk '{print $1}'`.chomp.split($/)
    list.each do |branch|
      run %[git branch -D "#{branch}"] if yes?("Delete #{branch}?")
    end
  end
end

task :search do
  desc 'search a string in branch / all branches / log'
  example 'search TODO'
  proc do |opts|
    string = opts[:args].first or error 'specify search string'
    choices = [
      ['current branch', %[git grep "#{string}"]],
      ['all branches',   %[git grep "#{string}" $(git rev-list --all)]],
      ['commit log',     %[git log -p --all -S "#{string}"]]
    ]
    idx = choose('Search in:', choices.map(&:first))
    run choices[idx][1] if idx
  end
end

# ---- open / pr (shortcuts; see also `open:` namespace) ----------------

task :open do
  desc 'open project page on GitHub/GitLab'
  proc { open_in_browser(remote_page_url) }
end

task :pr do
  desc 'create / view PR or MR for current branch'
  proc { open_in_browser(remote_pr_url) }
end

# ---- tags / users / stats --------------------------------------------

task :tag do
  desc 'tag the repo using ./.version'
  proc do |_|
    error 'no ./.version file' unless File.exist?('.version')
    version = File.read('.version').strip
    error 'empty ./.version' if version.empty?
    run %[git tag -a #{version} -m "$(git show -s --format=%s)"]
  end
end

task :tags do
  desc 'list tags'
  proc { run 'git tag -n' }
end

task :users do
  desc 'all users that have added to this git repo'
  proc { run 'git shortlog --summary --numbered --email' }
end

task :stat do
  desc 'git statistics for last 30 days'
  proc { run 'git-stat -d 30' }
end

task :rm do
  desc 'show how to remove file/dir from git tracking'
  proc do |opts|
    file = opts[:args].first or error 'specify a file'
    say <<~INFO
      # if file is not in git
      Put file in .git/info/exclude

      # if file is in git
      git update-index --assume-unchanged "#{file}"
      git update-index --no-assume-unchanged "#{file}"

      # list assume unchanged files
      git ls-files -v | grep "^[[:lower:]]"
      ---
    INFO
    run 'git ls-files -v | grep "^[[:lower:]]"'
  end
end

# ---- undo (top-level + namespace) -------------------------------------

task :undo do
  desc 'undo git add: git reset --mixed'
  proc { run 'git reset --mixed' }
end

namespace :undo do
  task :c do
    desc 'undo last commit: git reset --soft HEAD~'
    proc { run 'git reset --soft HEAD~' }
  end
end

# ---- rubocop ----------------------------------------------------------

task :rc do
  desc 'rubocop check of modified (unstaged) files'
  alt :rcop
  proc { rubocop_modified }
end

task :rubocop do
  desc 'rubocop check ALL files diffed from parent branch'
  proc do |_|
    files = `git diff #{PARENT}..#{BRANCH} --name-only`
      .split($/)
      .select { |f| %w[rb rake].include?(f.split('.').last) }
      .sort
    files -= ['db/schema.rb']
    next if files.empty?
    puts files
    run "rubocop #{files.join(' ')}"
  end
end

# ---- log (top-level + namespace) --------------------------------------

task :log do
  desc 'fancy log with graph'
  proc { run "git log --graph --pretty=format:'%Cred%h%Creset %aI -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit" }
end

namespace :log do
  task :simple do
    desc 'log without graph'
    proc { run "git log --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit" }
  end

  task :user do
    desc 'log entries for me (or another user)'
    example 'log:user'
    example 'log:user "Alice Smith"'
    proc do |opts|
      user = opts[:args].first || `git config user.name`.chomp
      run %{git log --date=short --pretty="%h %ad %an %s" --author="#{user}"}
    end
  end
end

# ---- open namespace (extras beyond top-level `open`) ------------------

namespace :open do
  task :diff do
    desc 'compare branch with parent on GitHub/GitLab'
    proc { open_in_browser(remote_compare_url) }
  end
end

# ---- reset namespace --------------------------------------------------

namespace :reset do
  task :hard do
    desc 'HARD reset branch to state on origin'
    proc do |_|
      next unless yes?('HARD RESET BRANCH TO ORIGIN, NO UNDO')
      run 'git fetch origin'
      run "git reset --hard origin/#{BRANCH}"
    end
  end

  task :local do
    desc 'reset to last local commit + clean -fd'
    proc do |_|
      next unless yes?('Reset branch to last local commit?')
      run 'git reset --hard && git clean -fd'
    end
  end

  task :head do
    desc 'fetch origin + reset HEAD to origin/HEAD'
    proc do |_|
      run 'git fetch origin'
      run 'git reset --hard origin/HEAD'
    end
  end
end

# ---- date surgery -----------------------------------------------------

task :squash do
  desc 'squash last commit into its parent + redate'
  proc do |_|
    unless `git status`.include?('working tree clean')
      run 'git add .'
      run 'git commit -m tmp-squash-message'
    end
    git_date = `git log -2 --date=format:"%Y-%m-%dT%T" --format="%ad"`.chomp.split($/).last
    run %[git reset --soft HEAD~2 && git commit --edit -m"$(git log --format=%B --reverse HEAD..HEAD@{1})"]
    do_redate(git_date)
  end
end

task :redate do
  desc <<~DESC
    fix commit date of latest commit
      redate <iso-date>             # set HEAD to date
      redate <iso-date> <commit>    # base on <commit>'s date
      redate +2                     # shift ~2 hours later
      redate -2                     # shift ~2 hours earlier
  DESC
  example 'redate 2020-04-05T21:03:27+00:00'
  example 'redate +2'
  proc do |opts|
    do_redate(opts[:args][0], opts[:args][1])
  end
end

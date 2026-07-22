# hammer

The bastard Frankenstein child of Rake](https://github.com/ruby/rake),
[Thor](https://github.com/rails/thor), and [Joshua](https://github.com/dux/joshua).
Sewn together from three good ideas, with the rest of each parent left on
the cutting room floor.

Drop a `Hammerfile`, run `hammer`, ship. AI LLM-s love `hammer`.

```ruby
namespace :db do                            # Rake-style colon paths
  task :migrate do                          # Joshua-style task block
    desc 'Run pending migrations'
    opt :pretend, type: :boolean, alias: :p # Thor-style typed opts
    proc do |o|
      say.green "migrating pretend=#{o[:pretend].inspect}"
    end
  end
end
```

```sh
$ hammer db:migrate --pretend
migrating pretend=true
```

## The bloodline

* **From [Rake](https://github.com/ruby/rake)** we took the *namespace
  tree* and *task prereqs* - `db:users:list` colon paths, `needs :env`
  dependencies, the one-file `Hammerfile` at the project root. Left on
  the table: the build-system DNA (file/mtime tasks) and that
  `task[a,b,c]` argument syntax nobody enjoys typing into a shell.

* **From [Thor](https://github.com/rails/thor)** we took *real CLI
  ergonomics* - typed options, defaults, aliases, required flags, and
  generated `-h` help. Left on the table: the four-constant top-level
  (`Thor`, `Thor::Group`, `Thor::Shell`, `Thor::Actions`), the
  parallel method-params-vs-`method_option` arg systems, the
  `HashWithIndifferentAccess`, and the file generator half of the gem
  that most CLIs never reach for.

* **From [Joshua](https://github.com/dux/joshua)** we took the
  *`task :name do ... end` block DSL* - declarative metadata up
  top, one `proc do |opts| ... end` at the bottom doing the work. No
  `def`-and-`desc` split, no class required, no boilerplate between
  "what this command is" and "what it does".

The result: ~400 lines of code, zero runtime dependencies, and a file
that reads top-to-bottom like a recipe.

## Install

```ruby
gem 'lux-hammer'
```

Or from the command line:

```sh
gem install lux-hammer
```

This installs the `hammer` binary and exposes `require 'lux-hammer'`.

### Install from GitHub (latest main)

```sh
curl -fsSL https://raw.githubusercontent.com/dux/hammer/main/install.sh | bash
```

Clones into `~/.local/share/lux-hammer` (override with `LUX_HAMMER_DIR=`),
builds the gem, and installs it. Re-run any time, or use:

```sh
hammer h:update   # git pull main + rebuild + reinstall
```

## Quick start

Create a `Hammerfile` in your project root:

```ruby
desc 'My project tools - build, deploy, test'

task :hello do
  desc 'say hi'
  proc do |opts|
    say.green "hello #{opts[:args].first || 'world'}"
  end
end
```

Then:

```sh
$ hammer hello
hello world
$ hammer hello dino
hello dino
$ hammer
Usage: hammer COMMAND [ARGS]

  My project tools - build, deploy, test

Commands:
  hammer hello  # say hi
```

That's it. `hammer` walks up from your current directory looking for a
`Hammerfile`, evaluates it, and dispatches.

The top-level `desc 'text'` is optional - one line (or multi-line via
a heredoc) describing what the CLI is for. It renders right under the
`Usage:` line in `hammer --help`.

## Why hammer (the short pitch)

A handful of papercuts from Rake and Thor that hammer just doesn't have.

### Rake task arguments are awkward

Rake forces you into `task[arg1,arg2]` syntax with no types, no flags,
no help, and shell-hostile brackets:

```ruby
# Rakefile
task :greet, [:name, :loud] do |_, args|
  puts args[:loud] == 'true' ? "HELLO #{args[:name].upcase}" : "hello #{args[:name]}"
end
```
```sh
$ rake 'greet[dino,true]'    # quotes required - zsh/bash treat [] as globs
```

Hammer takes typed options, positional fill, and any common flag form:

```ruby
# Hammerfile
task :greet do
  desc 'Say hello'
  opt :name
  opt :loud, type: :boolean, alias: :l
  proc { |o| say o[:loud] ? "HELLO #{o[:name].upcase}" : "hello #{o[:name]}" }
end
```
```sh
$ hammer greet dino -l              # positional fills :name, -l sets :loud
$ hammer greet --name=dino --loud   # or be explicit
$ hammer greet -h                   # real help, with defaults and examples
```

### Invoking another task

```ruby
# Rake
Rake::Task['db:migrate'].invoke('prod')
```
```ruby
# hammer - reads like a normal Ruby method call
hammer 'db:migrate', env: 'prod'
```

### Thor: `desc` welded to a method, no aliases, two arg systems

Thor splits arguments between method parameters and `method_option`,
needs a usage string repeated in `desc`, and has no first-class command
aliases (you reach for `map`):

```ruby
# Thor
class MyCli < Thor
  desc 'greet NAME', 'Say hello'              # usage repeated by hand
  method_option :loud, type: :boolean, aliases: '-l'
  def greet(name)                             # name is a method param...
    options[:loud] ? puts(name.upcase) : puts(name)   # ...options live elsewhere
  end
  map 'g' => :greet                           # aliases bolted on
end
```

```ruby
# hammer - one arg system, real aliases, no usage string to maintain
task :greet do
  desc 'Say hello'
  alt :g
  opt :name
  opt :loud, type: :boolean, alias: :l
  proc { |o| say o[:loud] ? o[:name].upcase : o[:name] }
end
```

Usage is generated from your `opt`s, `alt :g` registers a real alias,
and there's one place to look for everything the command takes.

## The two styles

### `task :name do ... end` (block DSL)

The block's **last expression must be `proc do |opts| ... end`**. That
proc is the handler. Everything before it is metadata.

```ruby
task :build do
  desc    'Build the project'
  example 'build prod -v'
  opt :verbose, type: :boolean, alias: :v
  opt :env,     default: 'dev'

  proc do |opts|
    say.green "building #{opts[:env]}"
  end
end
```

### `desc` + `def` (classic DSL)

For when you'd rather write a Ruby method:

```ruby
class MyCli < Hammer
  desc 'Build the project'
  opt :verbose, type: :boolean, alias: :v
  opt :env,     default: 'dev'
  def build(opts)
    say.green "building #{opts[:env]}"
  end

  desc 'Ping with no opts'
  def ping
    say 'pong'
  end
end

MyCli.start(ARGV)
```

`desc` is the trigger - a `def` without a preceding `desc` is just a
regular method, never a command. Methods with arity 0 are called
without opts; methods that take an argument receive the opts hash.

Both styles can coexist in the same class.

## Options (`opt`)

### Declaration

```ruby
opt :name,
    type:     :string,    # :string (default) :boolean :integer :float :array
    default:  nil,        # default value when omitted
    alias:    :n,         # one or many - see below
    desc:     'help text',# shown in `help COMMAND`
    req:      false       # raise at parse time if not supplied
```

Underscores in the name become dashes in the flag:
`opt :dry_run` → `--dry-run`. The kwarg key in `opts` is still
`:dry_run`.

### Invocation forms

For value options (anything that's not `:boolean`), all three forms work:

```
--port=3000        # long with equals
--port 3000        # long with space
-p 3000            # short alias with space  (requires alias: :p)
```

Not supported: attached short form (`-p3000`), combined short flags
(`-vf`).

For boolean options:

```
--verbose          # set to true (presence alone)
-v                 # short alias if declared
--no-reset         # also true if the opt is named :no_reset
```

There is **no** auto `--no-X` negation. Name the flag what you mean
(`:verbose`, `:no_reset`, `:force`).

### Per-type behavior

#### `:string` (default)

```ruby
opt :env, default: 'dev'
```
```
hammer build --env prod         # opts[:env] = "prod"
hammer build --env=prod         # opts[:env] = "prod"
hammer build                    # opts[:env] = "dev"  (default)
```

#### `:boolean`

```ruby
opt :verbose,  type: :boolean, alias: :v
opt :no_reset, type: :boolean
opt :cache,    type: :boolean, default: true
```
```
hammer build -v                 # opts[:verbose]  = true
hammer build --verbose          # opts[:verbose]  = true
hammer build --no-reset         # opts[:no_reset] = true  (name is the flag)
hammer build                    # opts[:cache]    = true  (default)
                                # opts[:verbose]  = nil   (no default)
```

Booleans never consume a positional. Presence → true; omitted → default
(or nil). Use `--flag=false` only if you need an explicit false value.

#### `:integer`

```ruby
opt :port, type: :integer, default: 3000, alias: :p
```
```
hammer serve --port 8080        # opts[:port] = 8080
hammer serve -p 8080            # opts[:port] = 8080
hammer serve                    # opts[:port] = 3000
```

Bad input raises a parse error: `--port=abc` → `invalid value for Integer()`.

#### `:float`

```ruby
opt :threshold, type: :float, default: 0.5
```
```
hammer scan --threshold 0.95    # opts[:threshold] = 0.95
```

#### `:array`

Comma-separated. No surrounding whitespace.

```ruby
opt :tags, type: :array, default: []
```
```
hammer deploy --tags a,b,c      # opts[:tags] = ["a", "b", "c"]
hammer deploy --tags=foo        # opts[:tags] = ["foo"]
hammer deploy                   # opts[:tags] = []
```

### Aliases (`alias:`)

A symbol becomes a flag automatically (1 char -> short, more -> long).
Strings starting with `-` pass through. One value or an array:

```ruby
opt :port,     alias: :p                   # -> -p
opt :pretend,  alias: :p                   # -> -p
opt :rollback, alias: :back                # -> --back  (multi-letter symbol)
opt :verbose,  alias: [:v, :V, :loud]      # -> -v, -V, --loud
opt :env,      alias: '-E'                 # string with `-` passes through
```

### Required

`req: true` raises a parse error if neither a flag nor a positional
fills the opt:

```ruby
opt :url, req: true
```
```
$ hammer deploy
[error] missing required --url
```

A positional satisfies it: `hammer deploy https://x.com` works because
of the declaration-order positional fill (see below).

### Defaults

`default:` is used when neither a flag nor a positional supplies the
value:

```ruby
opt :env, default: 'dev'
```

Note: boolean defaults of `nil` (the implicit default) and `false` are
not the same. `nil` means "not set; key absent from opts unless a flag
appears". Explicit `default: false` means "key always present, value
false unless `--flag` is passed".

### Positional fill (declaration order)

Anything in ARGV without `-` / `--` fills the next un-set
**non-boolean** opt, in declaration order:

```ruby
task :deploy do
  opt :url
  opt :env, default: 'dev'
  proc { |opts| ... }
end
```

These all produce the same `opts`:

```
hammer deploy https://x.com prod        # both positional
hammer deploy https://x.com --env=prod  # mixed
hammer deploy --url=https://x.com prod  # mixed reverse
hammer deploy --url=https://x.com --env=prod  # both flags
```

Rules recap:

* Boolean opts are skipped during positional fill.
* A flag value wins over a positional for the same opt.
* Leftover positionals go to `opts[:args]`.
* A positional satisfying a `req: true` opt counts as supplied.

### The `opts` hash

Always a `Hash` with **symbol keys**. Keys present:

* one per declared option that was supplied (via flag, positional, or
  default)
* `opts[:args]` - array of positional ARGV not absorbed by an opt

```ruby
task :show do
  opt :env, default: 'dev'
  opt :loud, type: :boolean
  proc { |opts| p opts }
end
```
```
$ hammer show foo bar --env=prod --loud
{env: "prod", loud: true, args: ["foo", "bar"]}

$ hammer show
{env: "dev", args: []}
```

### Stopping option parsing (`--`)

A bare `--` ends option parsing; everything after goes to `opts[:args]`
verbatim, even if it looks like a flag:

```
hammer build --env=prod -- --not-a-flag foo
# opts[:env]  = "prod"
# opts[:args] = ["--not-a-flag", "foo"]
```

## Namespaces (Rake-style colon paths)

Commands inside a `namespace :name do ... end` block are reached via
colon-paths from the root binary - just like `rake db:migrate`:

```ruby
namespace :db do
  task :migrate do
    proc { |opts| ... }
  end

  namespace :users do
    task :list do
      proc { |opts| ... }
    end
  end
end
```

Then:

```
hammer db:migrate
hammer db:users:list
hammer db                 # bare namespace lists everything under it
hammer db:                # trailing colon: full per-task help for every command
hammer db:migrate -h      # per-command help
hammer :                  # trailing colon at root: full help for every command
```

Namespaces nest to any depth. There is no per-level dispatch - the root
parses the whole colon path and walks the namespace tree.

## Pre-hooks (`before`)

A `before do ... end` block at the root scope or inside a `namespace`
runs before every command in that scope (and its nested namespaces).
Hooks fire outer -> inner, then the command's handler:

```ruby
before { hammer :env }                  # runs before every command

namespace :db do
  before { hammer :env }                # runs before every db:* command
  task :migrate do
    proc { |opts| ... }                 # no boilerplate require inside
  end
end
```

## Stdin, JSON input, and global options

Every command receives **`opts[:stdin]`** automatically when stdin is a
pipe (non-TTY) and non-empty; otherwise it is `nil`. Interactive TTYs are
never consumed.

```ruby
task :count do
  proc { |o| say "bytes=#{o[:stdin]&.bytesize || 0}" }
end
# cat file.txt | hammer count
```

### `type: :json` and `Hammer.prepare_json!`

For JSON bodies, declare `type: :json` and (optionally) coerce in a
`before` hook so pipes, `@file`, `-`, and inline JSON all land as a
**Hash/Array** on the same key:

```ruby
global_opt :json, type: :json, desc: 'JSON body (inline, @file, -, or pipe)'
before { |o| Hammer.prepare_json!(o) }   # fills o[:json] from stdin when unset

task :create do
  opt :name
  proc do |o|
    body = o[:json] || {}
    body[:name] ||= o[:name]
    # body is a Hash with symbol keys
  end
end
```

Supply the body any of these ways (equivalent when `prepare_json!` runs):

```sh
hammer create --json '{"name":"Ship"}'
hammer create --json @payload.json
cat payload.json | hammer create
cat payload.json | hammer create --json -    # explicit stdin
```

Rules for `Hammer.prepare_json!(opts, key: :json)`:

1. Already a Hash/Array → leave (symbolize keys).
2. String → parse inline JSON, `@path`, or `-` (stdin).
3. `nil` + stdin looks like `{` / `[` → parse stdin into `opts[key]`.
4. Boolean left alone (legacy `opt :json, type: :boolean` output flags).

`type: :json` **never** takes a bare positional (flag / file / pipe only),
so it won't steal `REF` from `update REF`.

### `global_opt`

Register options once at root (or a namespace); every command under that
scope accepts them. Shown under **Global options:** in help. Declared
**after** per-task opts for positional fill order.

```ruby
global_opt :json, type: :json
global_opt :as_json, type: :boolean, alias: :j, default: false,
           desc: 'Force JSON on stdout'
```

Helpers: `Hammer.prepare_json!`, `Hammer.attach_stdin!`, `Hammer::Input.*`.

`.env` and `.env.local` next to the `Hammerfile` are loaded
automatically by the `hammer` binary - no `before` hook needed.
Shell-set vars are never overwritten, and `.env.local` overrides
`.env`. Put `dotenv false` at the top of the Hammerfile to opt out:

```ruby
dotenv false                            # disable auto .env loading
```

`before` is intentionally not available inside `task` - the proc body
*is* the command body, just put the setup line at the top of the proc.

Pairs naturally with hidden commands (next section): keep `:env` /
`:app` setup as undocumented helpers and pull them in via `before`.

## Hidden commands (no `desc`)

A command declared without a `desc` is **hidden from help listings**
but stays fully dispatchable and `hammer`-callable:

```ruby
task :env do
  proc { |_| require './config/env' }   # no desc -> hidden
end

namespace :db do
  before { hammer :env }                # call it from a hook
  task :migrate do
    desc 'Run migrations'
    proc { |_| ... }
  end
end
```

`hammer` and `hammer db` won't list `env`, but `hammer env`,
`hammer :env` from another proc, and `before { hammer :env }` all work.

## Built-in tasks

The `hammer` binary auto-registers a small set of built-in tasks. All
the tool-meta commands live under the reserved `h:` namespace so they
can never collide with your project's own root tasks. They register the
same way with or without a Hammerfile and are always dispatchable, but
to keep the bare listing focused on your project they only show up
(under an `h:` section) in the extended `hammer --help` view.

Handled at the root (so the conventional invocations keep working):

* `:default` - fires on bare `hammer` and on leading-flag invocations.
  Hidden from listings. Prints the brief help by default and carries a
  `--version` / `-v` flag; override to wire up your own global flags.
* `hammer help [TARGET]`, `hammer -h`, `hammer --help` - prints the
  extended help view; `TARGET` accepts a command path or a `ns:` prefix.
  (Also available as `hammer h:help`.)

Under the `h:` namespace:

* `h:update` - rebuild + reinstall lux-hammer from main.
* `h:agents` - dump AGENTS.md (AI-friendly Hammerfile authoring docs).
* `h:version` - print the lux-hammer version.
* `h:recipes` - list / install / show / edit recipes.
* `h:init` - write a starter Hammerfile in cwd (refuses if one exists).
* `h:json` - dump the CLI definition as JSON (tasks grouped like the
  bare listing, with desc/options/examples/aliases/needs/cron); `--all`
  includes the `h:` tasks, `--compact` minifies. Output is plain stdout
  (the run banner goes to stderr), so `hammer h:json | jq` just works.
* `h:cron` - job server: runs every task that declares a
  `cron '<expr>'` schedule, with a localhost web UI for status and
  logs. See [Cron / job server](#cron--job-server).

Each is guarded by `unless commands.key?` within the namespace, so you
can override one by reopening `namespace :h` in your Hammerfile.

`--system` forces the no-Hammerfile branch - the Hammerfile in the
current tree (if any) isn't loaded for that invocation:

```sh
hammer --system h:recipes              # list recipes, ignoring any local Hammerfile
hammer --system h:recipes --install srt ~/bin/srt
```

`--gui` opens a native macOS window for the current project: a sidebar of
your tasks (grouped like the listing), a form per task built from its
options, and a Run button that streams the task's output. It reads the
project via `h:json` and runs each task as a `hammer <path> ...`
subprocess. macOS / arm64 only.

```sh
hammer --gui                           # open the runner for the nearest Hammerfile
```

Customize bare `hammer` by replacing `:default`:

```ruby
# Hammerfile

task :default do
  opt :version, type: :boolean, alias: :v
  opt :status,  type: :boolean, alias: :s

  proc do |opts|
    if opts[:version]
      say "myapp #{MyApp::VERSION}"
    elsif opts[:status]
      sh 'bin/myapp status'
    else
      hammer :help                # fall through to help
    end
  end
end
```

Or replace `:help` to add a banner:

```ruby
task :help do
  desc 'Show help (with a banner)'
  proc do |opts|
    say.cyan "MyApp #{MyApp::VERSION} - https://internal/docs"
    say ''
    self.class.root.print_help(opts[:args].first, extended: true)
  end
end
```

`-h` / `--help` stay reserved on every command - you can't shadow them
with an `opt`.

## Cron / job server

Any task can declare a schedule with `cron`; `hammer h:cron` then runs
those tasks on time, like a project-local crontab with a web UI:

```ruby
task :backup do
  desc 'Snapshot the database'
  cron '@daily'                    # 00:00 every day
  proc { |_| sh 'bin/backup' }
end

namespace :cache do
  task :warm do
    desc 'Refresh hot caches'
    cron '10m'                     # every 10 minutes
    proc { |_| sh 'bin/warm-cache' }
  end
end
```

Accepted schedule forms:

| form | example | meaning |
|---|---|---|
| 5-field cron | `*/10 * * * *` | standard crontab (`min hour dom mon dow`) |
| interval | `10s`, `10m`, `2h`, `1d` | every N seconds/minutes/hours/days, counted from the last run |
| shortcut | `@hourly`, `@daily`, `@weekly`, `@monthly` | expands to the cron equivalent |

Careful with raw cron fields: `10 * * * *` means "minute 10 of every
hour", not "every 10 minutes" - that's `*/10 * * * *`, or just `10m`.
Cron fields support `*`, `a`, `a-b`, `*/n`, `a-b/n` and comma lists
(numeric values only). Weekday `7` equals `0` (Sunday). Intervals are
not clock-aligned, so odd periods like `90m` work; a job that never ran
fires on the server's first tick. The scheduler ticks once per minute,
or once per second when any job declares a sub-minute interval.
Invalid expressions fail at Hammerfile load, not at runtime.

Run the server:

```sh
hammer h:cron                      # scheduler + web UI, Ctrl-C to stop
hammer h:cron --port=7777          # UI on another port (default 4267)
hammer h:cron --list               # print jobs + next runs, then exit
```

The web UI at `http://127.0.0.1:4267` (localhost only, never a public
interface) lists every job with its schedule, last/next run, status and
duration, shows per-job logs, and has a "run now" button for manual
triggers. `GET /json` serves the same status for scripting.

On a shared machine, protect the UI with HTTP basic auth - useful since
"run now" executes tasks:

```sh
hammer h:cron --pass=secret        # or: CRON_HTTP_PASS=secret hammer h:cron
curl -u :secret http://127.0.0.1:4267/json   # any username, password checked
```

Prefer the `CRON_HTTP_PASS` env var when other users can read your
process list (`ps` shows flag values). A `--service` unit generated
while `--pass` is set carries the flag along, so keep that file private.
Note this is plain HTTP - credentials are encoded, not encrypted; for
anything beyond localhost put a TLS proxy in front.

Each run executes in a fresh subprocess (`hammer ns:task` - same
isolation as the GUI runner), through the full normal pipeline: Bundler,
dotenv, `before` hooks, `needs`. Output goes to a per-job log:

```
log/hammer/backup.log              # current log (db:backup -> db-backup.log)
log/hammer/backup.log.1            # previous, rotated past 1 MB - max 2 files
tmp/hammer/cron.state.json         # last runs + server pid, survives restarts
```

You probably want `log/hammer/` and `tmp/hammer/` in `.gitignore`.

Overlap policy: if a run is still going when the next one comes due,
the new run is skipped (noted in the job log) - jobs never pile up.
Because last runs persist in the state file, a restart neither re-fires
jobs nor resets interval clocks, and a second `h:cron` for the same
project refuses to start while one is already running. Running state
survives restarts too: a job whose subprocess outlived a server crash
is picked up again as `running` (no double-start), and one that died
with the server shows `unknown` rather than a stale `running`.

To keep it running supervised, `--service` prints a ready-to-save
launchd plist (macOS) or systemd user unit (linux) - it only prints,
installing is up to you:

```sh
hammer h:cron --service > ~/.config/systemd/user/hammer-cron.service
systemctl --user enable --now hammer-cron
```

## Prereqs (`needs`)

Declare commands that must run before this one (Rake-style task deps):

```ruby
task :env do
  proc { |_| require './config/env' }     # hidden helper
end

task :app do
  needs :env                              # runs `env` first
  desc 'start the app'
  proc { |opts| App.start }
end

task :deploy do
  needs :env, :build                      # multiple prereqs, in order
  proc { |opts| ... }
end
```

Prereq names are colon paths resolved against the root class - same
lookup as `hammer`. Use `needs 'db:env'` to depend on a namespaced
command.

Each prereq fires **at most once per top-level invocation**, so if
`:app` needs `:env` and `:build` also needs `:env`, `:env` still runs
only once. Prereqs run with default options (no argv passed through).

`needs` vs `before`:
* `before { hammer :env }` - fires for *every* command in a scope.
* `needs :env` - declared per command, deduped across the call chain.

## Command aliases (`alt`)

`alt :short_name` (or several) registers extra names for a command:

```ruby
task :server do
  alt :s, :srv
  proc { |opts| ... }
end
```

Then `hammer server`, `hammer s`, and `hammer srv` all dispatch to the
same command. Alts work inside namespaces too: `alt :m` on `db:migrate`
makes `db:m` resolve.

## Cross-invocation (`hammer`)

From inside any command's proc - or from outside via the class - you can
invoke other commands without re-shelling out:

```ruby
task :deploy do
  proc do |opts|
    hammer :build, env: 'prod', verbose: true
    hammer 'db:migrate'
    say.green 'deployed'
  end
end
```

Signature: `hammer(name, *args, **opts)`. `name` is a symbol for a
single command or a colon-path string for namespaced commands. Trailing
positionals become positional ARGV; kwargs become CLI flags:

* `hammer :foo` → `foo`
* `hammer 'db:users:list'` → `db:users:list`
* `hammer :evaluate, 'puts 42'` → `evaluate "puts 42"` (positional ARGV)
* `verbose: true` → `--verbose`
* `no_reset: true` → `--no-reset` (underscores in the key become dashes)
* `dry_run: true` → `--dry-run`
* `env: 'prod'` → `--env=prod`
* `anything: false` → skipped (false flags are omitted)

`MyCli.hammer 'db:users:list', verbose: true` also works at the
class level, useful for tests and scripting.

## Chained dispatch (`+`)

Run several commands in one shot, Rake-style, using a bare `+` token
as the separator:

```sh
hammer build + deploy + notify
hammer build prod -v + db:migrate --pretend + deploy --url=https://x.com
```

Each segment is parsed and dispatched independently - its own opts,
its own positional args. `needs` prereqs dedupe across the whole
chain, so a shared `:env` step runs once even if every chained command
declares `needs :env`.

A `+` only acts as a separator when it arrives as its own argv token.
Quoting protects it: `--foo="a + b"` reaches the parser as a single
token and is left alone. To pass a literal `+` as a positional, double
it - `++` unescapes to a single `+`:

```sh
hammer echo ++ x          # echo gets positional args ["+", "x"]
hammer echo + bar         # runs echo, then runs bar
```

## Shell helpers

These are mixed into every handler (and also live on `Hammer::Shell` for
direct use).

### `say` - print a line

```ruby
say 'plain output'             # no color
say.green 'ok'                 # color via proxy (preferred)
say.cyan  "env=#{env}"         # interpolation works the same
say 'equivalent', :green       # two-arg form is still supported
say ''                         # blank line
```

`say` with no args returns a tiny proxy that exposes one method per
color: `say.red 'x'` is just `say('x', :red)`. The proxy form reads
better when colors are the common case. Use `say ''` for an explicit
blank line.

### `String#color` - paint a string without printing

```ruby
label = 'OK'.color(:green)
puts "[#{label}] done"         # embed colored chunks anywhere

Hammer::Shell.paint('x', :red) # the underlying primitive `say` uses
```

### Colors

Valid names: `:black :red :green :yellow :blue :magenta :cyan :white :gray`.
Unknown colors (in `say`, `say.<color>`, `paint`, or `String#color`)
raise `Hammer::Error` listing the valid names - even when colors are
disabled, so typos fail loudly in CI.

Colors are auto-disabled when stdout isn't a TTY or when `NO_COLOR` is
set. Force on/off programmatically:

```ruby
Hammer::Shell.color!(true)     # force ANSI on
Hammer::Shell.color!(false)    # force off
Hammer::Shell.color?           # current state (bool)
```

### `error` - controlled failure

```ruby
error 'config file missing' unless File.exist?('config.yml')
# -> dispatcher prints "[error] config file missing" in red, exits 1
# No backtrace, no per-command help spam.
```

Internally it just raises `Hammer::Error`; the dispatcher catches it.

### `ask` - read one line from stdin

```ruby
name = ask 'your name'                       # required-style prompt
env  = ask 'env', default: 'dev'             # blank input -> "dev"
```

The prompt is shown in cyan with the default in brackets when present.
Returns the typed line (chomped) or the default on a blank line.

### `yes?` - y/N confirmation

```ruby
exit 0 unless yes? 'continue?'               # anything starting with y/Y -> true
                                             # blank, n, anything else -> false
```

### `choose` - arrow-key picker

```ruby
envs = %w[dev staging prod]
idx  = choose 'Pick env', envs
say.green "deploying to #{envs[idx]}" if idx
```

While the picker is up: `j`/`k` or `↑`/`↓` to move, `Enter` to confirm,
`q` / `ESC` / Ctrl-C to cancel. Returns the integer index of the
selected item, or `nil` on cancel.

When stdin isn't a TTY (pipes, redirected scripts, tests), `choose`
falls back to a numbered prompt: it prints each item with a number and
reads a line - same return contract, so calling code doesn't change.

```
$ echo 2 | mycli some-cmd
Pick env
  1) dev
  2) staging
  3) prod
select [1-3]:
# idx -> 1 (zero-based)
```

### `sh` - run a shell command, abort on failure

```ruby
sh 'bundle install'                          # echoes "$ bundle install" in gray
sh "git tag v#{version}"                     # raises Hammer::Error on non-zero
```

Returns `true` on success. On non-zero exit it raises `Hammer::Error`,
which the dispatcher turns into `[error] command failed: ...` + exit 1.

## Splitting across files (`load`)

Once a `Hammerfile` grows past a screen or two, split it. Drop fragments
in any file ending in `_hammer.rb` and pull them in with `load`:

```ruby
# Hammerfile
load auto: true              # recursive scan for *_hammer.rb from here
```

```ruby
# tasks/db_hammer.rb
namespace :db do
  task :migrate do
    desc 'Run pending migrations'
    opt :pretend, type: :boolean, alias: :p
    proc { |o| say.green "migrating pretend=#{o[:pretend].inspect}" }
  end
end
```

```ruby
# tasks/deploy_hammer.rb
task :deploy do
  desc 'Deploy to prod'
  proc do |_|
    hammer 'db:migrate'      # cross-file invocation just works
    say.cyan 'deployed'
  end
end
```

### Call shapes

```ruby
load                         # same as load auto: true
load auto: true              # recursive scan for *_hammer.rb under caller dir
load 'tasks/db_hammer.rb'    # one file (path relative to caller)
load 'tasks/*_hammer.rb'     # glob
load 'a.rb', 'b.rb'          # several explicit paths
load 'tasks'                 # directory -> recursive scan under it (empty OK)
```

Paths resolve relative to the file calling `load`, not cwd. Inside a
`Hammerfile` that means "relative to the Hammerfile"; inside a class
body it means "relative to that file".

A directory argument is the explicit-anchor twin of `load auto: true` -
walks the directory for `*_hammer.rb` with the same skip rules. Useful
when you want to pull fragments from a known sibling tree without
making it the caller's dir.

### What's skipped

Auto-discovery walks recursively but skips `.git`, `.bundle`,
`node_modules`, `tmp`, `vendor`, `dist`, `build`, `coverage`, and any
hidden directory.

### Fragment shape

A `*_hammer.rb` file is a **block-DSL fragment** - same surface as a
`Hammerfile`: `task`, `namespace`, and nested `load`. Not a class
re-open. If you want to extend a `Hammer` subclass in the classic
`desc` + `def` style across files, use plain `require_relative`.

### Dedup and re-entrancy

Each file loads at most once per target class, keyed by absolute path.
A fragment can `load` other fragments without worrying about cycles.

### Errors

If a fragment raises during load, the error surfaces as
`failed loading <path>: <message>` so you know which file blew up.
An explicit pattern (`load 'x_hammer.rb'`, `load 'tasks/*.rb'`) that
matches zero files raises; auto-mode finding nothing is silent.

## Block DSL outside a Hammerfile

Same shape as a Hammerfile, just inline:

```ruby
require 'lux-hammer'

Hammer.run(ARGV) do
  task :hello do
    desc 'say hi'
    opt :loud, type: :boolean, alias: :l
    proc do |opts|
      msg = "hello #{opts[:args].first || 'world'}"
      msg = msg.upcase if opts[:loud]
      say.cyan msg
    end
  end
end
```

### `Hammer.run` without a block

If you call `Hammer.run(ARGV)` with no block, it does the obvious thing
relative to `Dir.pwd`:

* If `./Hammerfile` exists, it's evaluated as the block DSL.
* Otherwise, `*_hammer.rb` files under `Dir.pwd` are auto-discovered
  (same walk + skip rules as `load auto: true`).

Either way ARGV is dispatched against the resulting CLI. Useful for a
one-line custom bin:

```ruby
#!/usr/bin/env ruby
require 'lux-hammer'
Hammer.run ARGV
```

For more control - e.g. loading a Hammerfile from a fixed path *and*
auto-discovering from cwd - pass a block and use `load` explicitly:

```ruby
Hammer.run ARGV do
  load File.join(MY_ROOT, 'Hammerfile')
  load Dir.pwd if Dir.pwd != MY_ROOT
end
```

### `#!/usr/bin/env hammer` (single-file scripts)

For a one-off CLI that lives as a single executable file, point the
shebang straight at `hammer` - no `require`, no boilerplate:

```ruby
#!/usr/bin/env hammer
# desc: tiny greeter

task :hello do
  desc 'say hi'
  opt :loud, type: :boolean, alias: :l
  proc do |opts|
    msg = "hello #{opts[:args].first || 'world'}"
    say.cyan(opts[:loud] ? msg.upcase : msg)
  end
end
```

```sh
$ chmod +x greet
$ ./greet hello dino -l
HELLO DINO
$ ./greet --help
Usage: greet COMMAND [ARGS]
  ...
```

The file body is plain Hammerfile DSL (`task`, `namespace`, `before`,
`load`). `hammer` detects the shebang, evaluates the script as a
self-contained CLI, and uses the script's basename as the program name
in help - so `./greet --help` reads "Usage: greet ..." rather than
"Usage: hammer ...". The current working directory is left alone, so
relative paths inside the script resolve where the user ran it.

## Complete example (every feature)

```ruby
# Simple top-level command
task :build do
  desc    'Build the project'
  example 'build prod -v'
  example 'build --env=staging'
  opt :verbose, type: :boolean, alias: :v, desc: 'verbose output'
  opt :env,     default: 'dev', desc: 'target env'

  proc do |opts|
    target = opts[:args].first || opts[:env]
    say.green "building #{target}"
    say '  verbose on' if opts[:verbose]
  end
end

# Command that calls another command
task :deploy do
  desc 'Deploy to URL'
  alt :ship
  opt :url, req: true
  opt :force, type: :boolean

  proc do |opts|
    hammer :build, env: 'prod'
    exit 0 unless yes? "deploy to #{opts[:url]}?" unless opts[:force]
    say.yellow "deploying to #{opts[:url]}"
  end
end

# Namespace with two levels of nesting
namespace :db do
  task :migrate do
    desc 'Run pending migrations'
    alt :m
    example 'db:migrate 3 --pretend'
    opt :pretend, type: :boolean, alias: :p

    proc do |opts|
      step = opts[:args].first || 'all'
      say.green "migrating #{step} pretend=#{opts[:pretend].inspect}"
    end
  end

  namespace :users do
    task :list do
      desc 'List users'
      opt :role, default: 'all'
      opt :limit, type: :integer, default: 100

      proc do |opts|
        say.cyan "users role=#{opts[:role]} limit=#{opts[:limit]}"
      end
    end

    task :create do
      desc 'Create a user'
      opt :email, req: true
      opt :admin, type: :boolean

      proc do |opts|
        say "create #{opts[:email]} admin=#{opts[:admin]}"
      end
    end
  end
end
```

```sh
$ hammer
Usage: hammer COMMAND [ARGS]

Commands:
  hammer build               # Build the project
  hammer deploy (alt: ship)  # Deploy to URL

db:
  hammer db:migrate (alt: m)  # Run pending migrations

db:users:
  hammer db:users:list       # List users
  hammer db:users:create     # Create a user

$ hammer build prod -v
building prod
  verbose on

$ hammer deploy --url=https://example.com --force
building prod
deploying to https://example.com

$ hammer db:m 3 -p           # alt 'm' + positional + short bool
migrating 3 pretend=true

$ hammer db:users:create --email=dino@example.com --admin
create dino@example.com admin=true

$ hammer db                  # bare namespace shows its contents
Usage: hammer db:COMMAND [ARGS]

Commands:
  hammer db:migrate (alt: m)  # Run pending migrations

users:
  hammer db:users:list        # List users
  hammer db:users:create      # Create a user

$ hammer db:users:create -h
Usage: hammer db:users:create EMAIL [OPTIONS]
  Create a user

Options:
  --email EMAIL (required)
  --admin
```

## Recipes (shareable mini-CLIs shipped with hammer)

A **recipe** is a standalone Hammerfile-style script bundled inside the
`lux-hammer` gem under `recipes/`. Each recipe is exposed as its own
top-level binary in your `PATH` - so `srt` becomes a real command, not
`hammer srt:shift`.

Recipe management lives under the `h:recipes` task, reachable from
anywhere (inside a project the `h:` namespace can't shadow your root
tasks). `--system` skips loading a local Hammerfile if you want a clean
environment.

Listing what's available:

```sh
$ hammer h:recipes                    # from any directory
$ hammer --system h:recipes           # ignoring any local Hammerfile
gem:
  srt  # Subtitle (.srt) toolkit - shift timestamps, show stats
         [install: hammer h:recipes --install srt]
  llm  # personal LLM utility CLI (memory store, prompt-token expander, ...)
         [install: hammer h:recipes --install llm]
```

Installing one. With no TARGET, the stub is printed to stdout (you
redirect it yourself); with a TARGET path, lux-hammer writes the file
and chmods +x in one step:

```sh
$ hammer h:recipes --install srt ~/bin/srt    # write + chmod
$ hammer h:recipes --install srt > ~/bin/srt && chmod +x ~/bin/srt
$ srt --help
Usage: srt COMMAND [ARGS]

  Tiny .srt subtitle helper.

Commands:
  srt info   # Print cue count and total duration
  srt shift  # Shift every timestamp by N seconds
```

The stub is a 3-line Ruby wrapper that re-enters lux-hammer at runtime,
so the recipe always runs the version currently in the gem.

### Authoring your own

Drop a plain `.rb` file in `~/.config/hammer/recipes/`. The first
`# desc: ...` comment is what shows in `hammer h:recipes`. The file body
uses the same DSL as a Hammerfile - `task`, `namespace`, `before`,
`load`. Example `~/.config/hammer/recipes/json.rb`:

```ruby
# desc: tiny JSON pretty-printer / minifier

task :pretty do
  desc 'Pretty-print JSON from stdin or a file'
  proc do |opts|
    require 'json'
    src = opts[:args].first ? File.read(opts[:args].first) : $stdin.read
    puts JSON.pretty_generate(JSON.parse(src))
  end
end
```

Install it the same way:

```sh
$ hammer h:recipes --install json ~/bin/json
```

User-dir recipes override gem recipes with the same name, so you can
fork without forking.

### Other `h:recipes` actions

```sh
hammer h:recipes                            # list all
hammer h:recipes --install                  # interactive picker, then prints stub
hammer h:recipes --show NAME                # cat the recipe source
hammer h:recipes --path NAME                # absolute path
hammer h:recipes --edit NAME                # open in $EDITOR (copies gem -> user dir first)
hammer h:recipes --run  NAME [ARGS]         # run without installing its bin
hammer h:recipes --run  NAME -- --help      # `--` forwards flags to the recipe
```

## Programmatic use

Outside a Hammerfile, you can build a `Hammer` subclass and run it
directly. Useful for embedding or testing:

```ruby
require 'lux-hammer'

class MyCli < Hammer
  task :greet do
    opt :loud, type: :boolean
    proc do |opts|
      msg = "hello #{opts[:args].first}"
      say(opts[:loud] ? msg.upcase : msg)
    end
  end
end

MyCli.start(ARGV)         # or:
MyCli.hammer :greet, loud: true
```

## Development

```sh
git clone https://github.com/dux/hammer
cd lux-hammer
bundle install
bundle exec rake test
```

Tests live in `test/` and use minitest. Run a single file with
`bundle exec ruby -Ilib -Itest test/parser_test.rb`.

## How hammer compares to Thor and Rake

Short version: hammer carves a sweet spot between the two. It's a tiny
CLI builder with Rake's namespacing and a cleaner DSL than Thor, plus a
few small things that have been bugging me about both for years.

### Versus Thor

| | Thor | hammer |
|-|-|-|
| Runtime deps | a few | zero |
| Command DSL | `desc 'usage', 'help'` + `method_option` + `def name(arg)` | `task :name do ... proc do \|opts\| end end` (or classic `desc` + `def`) |
| Opts container | `Thor::CoreExt::HashWithIndifferentAccess` | plain `Hash` with symbol keys |
| Positional args | method positional params + `method_option`, two parallel systems | declared-order opts fill from positional, single system |
| Sub-namespaces | `register SubClass, 'name', '...'` (inheritance ceremony) | `namespace :name do ... end` (no classes needed) |
| Command aliases | none (workarounds via `map`) | `alt :s, :srv` |
| Pre-hooks | none built-in | `before { ... }` per scope, `needs :env` per command |
| Chained dispatch | no | `hammer build + deploy + notify` |
| Cross-invoke | `invoke 'name', [args], opts` | `hammer :name, **opts` (looks like a method call) |
| Inline CLI | class only | class DSL **or** `Hammer.run do ... end` block DSL **or** a `Hammerfile` |

**What hammer does better and why:**

* **The opts hash is just a Hash.** Symbol keys, always. No magic accessor
  object to remember, no string-vs-symbol confusion, no method_missing.
* **Positional args fill opts in declaration order.** Thor either forces
  you into method params (which then clash with options) or makes you read
  `ARGV` yourself. Hammer just says: opts you declared come first, leftover
  goes to `opts[:args]`.
* **Cross-invocation reads as Ruby.** `hammer 'db:migrate', env: 'prod'`
  looks like a method call. Thor's `invoke('db:migrate', [], env: 'prod')`
  always feels like reflection.
* **No generator complexity.** Thor's other half is file scaffolding and
  ERB templates. If you don't need that (and most CLIs don't), Thor still
  drags it along.

### Versus Rake

| | Rake | hammer |
|-|-|-|
| Primary use case | build/task automation with file deps | general CLIs |
| Task file | `Rakefile` | `Hammerfile` (walks up parent dirs) |
| Namespacing | colon paths (`db:migrate`) | colon paths (`db:migrate`) - parity |
| Per-task options | `task[a,b,c]` positional only | typed `opt`s with flags, aliases, defaults, required |
| Help | `rake -T` (plain list) | bare `hammer` lists everything grouped by namespace; `hammer X -h` for per-command help with examples and defaults |
| Cross-invoke | `Rake::Task['db:migrate'].invoke` | `hammer 'db:migrate'` |
| Prerequisites | `task :build => [:clean, :compile]` (declarative DAG) | `needs :clean, :compile` (declarative, deduped across `+` chains) |
| Pre-hooks | none built-in | `before { ... }` scoped to root or namespace |
| Chained dispatch | no (multi-task argv runs sequentially, no per-task flags) | `hammer build prod -v + db:migrate --pretend + deploy` |
| File tasks | yes (mtime-based) | no |
| Aliases | none (workarounds via re-defined tasks) | `alt :short_name` |
| Split across files | `import 'other.rake'` | `load auto: true` (or explicit paths/globs) |
| Shareable scripts | no | recipes (one-file CLIs installable as their own binary) |

**What hammer does better and why:**

* **Per-command options with types.** Rake's `task[a,b]` syntax is a
  long-standing wart - no types, no validation, awkward to type in the
  shell, no help. `opt :port, type: :integer, default: 3000` is what
  every CLI library has converged on.
* **Help is actually useful.** `hammer build -h` shows usage, options
  with defaults and required markers, and examples. `rake -T` is just a
  list of one-liners.
* **Command aliases.** `alt :m` for `db:migrate` is two characters of
  declaration. Rake makes you redefine the task or use prerequisites.
* **CLI semantics.** Rake assumes "build artifacts from sources"; it's
  great at that. Hammer assumes "give me commands with arguments and
  flags"; it's better at that.

**What Rake does better:**

* **File tasks with mtime tracking.** `file 'foo.o' => 'foo.c' do ... end`
  skips work when the target is newer than the source. Genuine win for
  compilation pipelines. Hammer doesn't have this and isn't going to -
  it's not what a CLI builder is for.

### When to pick which

* **CLI for a tool, app, or service** (run servers, manage data, ship
  releases, scripts your team uses) - **hammer**.
* **Build pipeline with file-mtime dependencies** (compiling assets,
  generating code, classic Make-style work) - **Rake**.
* **Need to ship file generators / templates** (Rails-style
  scaffolding) - **Thor**.

## License

MIT - see [LICENSE](LICENSE).

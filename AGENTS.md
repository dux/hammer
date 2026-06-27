# AGENTS.md - lux-hammer

Conventions and constraints for AI agents working on this gem.

## What this gem is

A tiny CLI builder stitched together from three influences:
namespaces and prereqs from Rake, typed option parsing from Thor, and
the `task :name do ... end` block DSL from Joshua. Users drop a
`Hammerfile` in their project, run `hammer`, get a structured CLI. Also
usable as a library (`require 'lux-hammer'`, subclass `Hammer`, call
`.start(ARGV)`).

## Hard constraints

* **One root constant**: `Hammer`. Never pollute `Object` or introduce
  another top-level constant. Sub-types live as `Hammer::Shell`,
  `Hammer::Option`, `Hammer::Parser`, `Hammer::Command`,
  `Hammer::Loader`, `Hammer::Builder`, `Hammer::CommandBuilder`. The one
  exception is `String#color(:name)` (defined in `lib/hammer/shell.rb`)
  - a tiny convenience for `"hi".color(:cyan)`. Do not add more
  monkey-patches.
* **Zero runtime dependencies**. The gem must work with stdlib only. New
  dependencies require explicit user approval.
* **Ruby >= 2.7**. Do not use language features introduced after 2.7
  without flagging.
* **`desc` is single-arg, multi-line allowed**. The argument is one
  string; it may contain newlines. The first line is the brief shown in
  command listings, the full string renders (indented) in per-command
  help. Trailing whitespace is stripped so heredocs work cleanly. `desc`
  is never multi-arg - that form was tried and reverted.
* **The `proc` is the trailing expression of a `task` block.** Do not
  introduce `run do ... end` or similar - the user explicitly chose this.

## File layout

```
bin/hammer                  # CLI entry point
lib/lux-hammer.rb           # Entry - defines class Hammer and its DSL
lib/hammer/shell.rb         # ANSI/IO helpers
lib/hammer/option.rb        # One option definition
lib/hammer/parser.rb        # ARGV -> [positional, opts_hash]
lib/hammer/command.rb       # One registered command (name, opts, alts, handler)
lib/hammer/loader.rb        # `*_hammer.rb` fragment loader (auto/glob/file)
lib/hammer/builder.rb       # Block-DSL context (Hammerfile / Hammer.run)
lib/hammer/command_builder.rb # `task :name do ... end` context
lib/hammer/recipe.rb        # Recipe discovery (gem + user dir, desc, stub)
lib/hammer/builtins.rb      # Built-in tasks (recipes, update, agents, version, init, ...)
recipes/                    # Bundled recipes (each `<name>.rb` -> a bin via stub)
test/dsl_test.rb            # DSL surface, dispatch, help formatting
test/load_test.rb           # `load` / `*_hammer.rb` fragment loader
test/parser_test.rb         # ARGV parsing edge cases
test/option_test.rb         # Option declaration / casting
test/command_test.rb        # Command data type
test/shell_test.rb          # ANSI / IO helpers
test/cli_test.rb            # `hammer` binary end-to-end
examples/Hammerfile         # Reference Hammerfile
examples/class_dsl.rb       # Reference class DSL usage
examples/block_dsl.rb       # Reference block DSL usage
```

## DSL surface (do not break compatibility silently)

Inside a `task :name do ... end` block (CommandBuilder context):

* `desc 'short description'` (string may contain `\n`; first line is
  the brief shown in listings, full text renders in per-command help)
* `example 'invocation example'` (callable many times)
* `opt :name, type:, default:, alias:, desc:, req:` - any other kwarg
  raises `Hammer::Error` ("unknown opt parameter(s)")
* `alt :other_name` (callable many times)
* `needs :other_cmd, 'ns:cmd'` - prereqs run before the handler;
  resolved against root (same lookup as `hammer`), deduped per
  top-level `start` so each prereq fires at most once. Dedupe also
  spans `+`-chained segments. Unknown prereq raises `Hammer::Error`.
* `proc do |opts| ... end` - **the last expression**, becomes handler

At class scope (for `def`-style commands):

* `desc`, `example`, `opt`, `alt`, `needs` set pending state
* The next `def` consumes the pending state IF `desc` was set; otherwise
  the method is treated as a plain helper
* Methods with arity 0 are called without opts; methods that take an arg
  receive the opts hash

At Hammerfile (block-DSL) top-level scope only:

* `desc 'CLI description'` - top-level summary shown under the `Usage:`
  line in `hammer --help`. Multi-line allowed (via heredoc). This is
  distinct from the class-DSL `desc` (which sets per-task pending
  state for the next `def`).
* `helpers do ... end` - shorthand for `class_eval` on the underlying
  Hammer subclass. Use it to define private instance methods that task
  procs can call as bare names (procs are `instance_exec`'d on the
  subclass instance, so anything defined here is in scope). Helpers
  can also call `say` / `choose` / `error` / `yes?` directly since
  Hammer mixes in `Shell`.

At class or `Hammerfile` scope:

* `task :name do ... end` - redefining a task is last-write-wins. A
  warning fires (and the entry is tagged `(redefined)` in help) **only**
  when the task it clobbers was also defined inside the main app (cwd).
  Overriding a task that came from outside - a framework default, plugin,
  or gem (an absolute path outside cwd) - is treated as an intentional
  override and stays silent. Locality is read off the location string:
  `relativize_path` rewrites in-app absolutes to a `.`-relative form, so
  anything still starting with `/` is external (see `app_local_location?`).
* `namespace :name do ... end` - `:self` is reserved for the `hammer`
  binary's built-in namespace (see `lib/hammer/builtins.rb`). Defining
  it from user code raises. Reopening a namespace **merges** (Rake-style):
  the same `namespace :db` can be split across files / `load`ed fragments
  and the blocks accumulate onto one subclass - no warning. Only a
  duplicate *task* name warns (handled by `task`, last write wins).
* `dotenv false` - opt out of auto `.env` / `.env.local` loading.
  Only meaningful from the `hammer` binary (`Hammer.cli`); the load
  happens after Hammerfile evaluation, before dispatch. Shell-set vars
  always win (`ENV[k] ||= v`). For full dotenv-gem features
  (interpolation, multiline) keep `dotenv false` and call `Dotenv.load`
  from a `before` hook instead.
* `load` / `load auto: true` / `load 'path/file.rb'` / `load 'glob/*.rb'` /
  `load 'some/dir'` - pull in Hammerfile fragments from `*_hammer.rb`
  files. Paths resolve relative to the caller's file. A directory
  argument triggers the same recursive scan as `load auto: true` but
  anchored at the given dir (empty result is OK, no error - apps with
  no fragments are normal). Globs and explicit file paths still raise
  on zero matches as a typo guard. Fragments are de-duplicated per
  target class, so re-entrant `load` is safe. Skipped dirs:
  `.git`, `.bundle`, `node_modules`, `tmp`, `vendor`, `dist`, `build`,
  `coverage`, plus any hidden dir. Fragment shape is the block DSL
  (`task`, `namespace`); class-DSL fragments belong in plain `.rb`
  files loaded with `require_relative`.

Runtime cross-invocation:

* `hammer(name, *args, **opts)` - `name` is a symbol for a top-level
  command (`hammer :build`) or a colon-path string for namespaced ones
  (`hammer 'db:users:list'`). Trailing positionals become positional
  ARGV. Kwargs become flags: underscores in keys map to dashes,
  `true` -> `--flag`, `false` -> skipped (use `no_x: true` to negate),
  any other value -> `--key=value`. Available both on a class
  (`MyCli.hammer ...`) and inside a handler proc.

## Entry points

* `Hammer.run(argv = ARGV) { ... }` - inline block DSL, builds an
  anonymous subclass, dispatches `argv` against it.
* `Hammer.run(argv = ARGV)` - **without a block**: load `./Hammerfile`
  if present, otherwise auto-discover `*_hammer.rb` under `Dir.pwd`,
  then dispatch. No walk-up, no chdir. The "do the obvious thing"
  entry point for a fixed bin script; users who need
  walk-up + chdir + missing-Hammerfile error use `Hammer.cli`
  (`bin/hammer`).
* `Hammer.cli(argv = ARGV)` - internal entry for `bin/hammer` only:
  walks up from `Dir.pwd` for a `Hammerfile`, chdirs into its dir,
  errors if none found anywhere up the tree (unless the invocation
  routes to a built-in - see `dispatches_to_builtin?` /
  `looks_like_builtin?`, true for bare invocation / leading flag /
  explicit help / an `h:`-namespace path). After evaluating the
  Hammerfile, registers the built-ins via `Hammer::Builtins.register`:
  `:default` at the root (backs bare invocation, carries `--version`)
  plus the `h:` namespace (`h:help`, `h:update`, `h:agents`,
  `h:version`, `h:recipes`, `h:init`). The full set registers in every
  context - living under `h:` means they can't collide with project
  root tasks, so there's no core/no-project split. Each is guarded by
  `unless commands.key?(...)` so a user who reopens `namespace :h` wins
  silently. The `--system` flag is peeled off argv at the top and
  forces the no-Hammerfile branch. Not part of the user-facing surface
  - don't recommend it in examples; `Hammer.run` is what library users
  should reach for.
* `Hammer.recipe(name, argv = ARGV)` - entry for recipe stubs in PATH.
  Loads `<gem>/recipes/<name>.rb` (or its user-dir override), runs as
  a standalone CLI with `program_name = name`. No Hammerfile lookup,
  no chdir, no dotenv auto-load. See `lib/hammer/recipe.rb`.
* `class MyCli < Hammer; ... end; MyCli.start(ARGV)` - classic class
  DSL. `.start` is the dispatch primitive everything else funnels into.

## `opts` hash contract

Always a `Hash` with **symbol keys**. Never change this without an
explicit ADR-level discussion. Keys:

* one per declared option
* `opts[:args]` - leftover positional ARGV (after declaration-order
  fill)

## Dispatch model

* Commands are addressed by colon path: `db:users:list`.
* The root `Hammer` subclass holds `@commands` and `@namespaces`.
* `resolve('a:b:c')` walks `@namespaces['a'].namespaces['b']` and
  finds command `c` in the last class.
* Each segment is fuzzy-matched: exact name/alt first, then prefix
  (`b` -> `build`), then substring (`es` -> `test`). Per-scope: matching
  only looks at this class's commands/namespaces, not globally across
  the tree. Ambiguous fuzzy matches raise `Hammer::AmbiguousMatch`,
  which `dispatch` catches and prints as
  `multiple commands match 'b': bake, build`. Same fallback applies to
  namespaces via `find_namespace`.
* `resolve` and `resolve_namespace` return a `canonical` colon-path
  alongside the resolved class/command, so help banners and the
  pre-run banner display the canonical name even when the user typed
  a fuzzy prefix.
* Before a command's handler runs, `run_command` prints a gray
  `> prog cmd --opt=val ARG` banner so it's visible which command was
  actually picked when fuzzy matching kicks in. Only options that
  differ from their default are listed; booleans render as `--flag`
  / `--no-flag`. Help paths (`-h`, bare namespace) short-circuit
  before the banner. Set `HAMMER_QUIET=1` to suppress the banner
  globally - useful when a task writes machine-readable output to
  stdout (e.g. a JSON-emitting Claude Code / Codex hook).
* There is **no per-level dispatch**. A namespace is a container, not a
  CLI of its own. Do not reintroduce `subclass.start(remaining_argv)`.
* `start(argv)` is a two-step pipeline: `split_chain(argv)` (private)
  splits on bare `+` tokens and unescapes `++` -> `+`, then `dispatch`
  (private) runs each segment. `start` is the only public entry that
  also sets up the per-invocation `needs`/`before` dedupe state, so the
  whole `+` chain shares one dedupe scope. Don't have `dispatch` call
  back into `start` for sub-segments - that re-triggers chain detection
  on already-unescaped `+` tokens (bug we fixed; the test
  `test_chain_escape_double_plus_yields_literal_plus_arg` guards it).

## Help formatting

* Program name in usage lines is computed automatically (invocation path
  relative to cwd if the bin lives inside cwd, otherwise the basename of
  `$PROGRAM_NAME`). There is no user-facing override; the auto-detection
  is the whole API. `Hammer.cli` warms the cache before chdir-ing into
  the Hammerfile's directory so the resolved name stays relative to the
  cwd the user invoked from.
* `hammer` (no args) routes to the `:default` built-in task, which
  falls through to `print_help(extended: false)` - the brief command
  listing with a top gray `lux-hammer VERSION - <homepage>` banner.
* `hammer -h` / `--help` / `help [TARGET]` routes to the `:help`
  built-in task, which calls `print_help(target, extended: true)` -
  adds global flags (rendered from `:default`'s declared opts),
  `Recipes:` section (hammer binary only), a small Hammerfile example,
  and the footer link.
* `hammer COMMAND -h` / `--help` prints per-command help (reserved on every command).

## Built-in tasks (user-overridable)

`Hammer::Builtins.register(klass)` is the single registration entry
point. It runs **after** Hammerfile evaluation and skips each task when
the user already defined it (`unless commands.key?(name)` - no
redefinition warning). The same set registers in every context (project
or bare binary): `:default` at the root, everything else under the
reserved `h:` namespace.

* Root: `:default` (hidden, carries `--version` / `-v`).
* `h:` namespace: `h:help`, `h:update`, `h:agents`, `h:version`,
  `h:recipes`, `h:init`.

`h:` is the reserved built-in namespace - keeping the tool-meta commands
there means they never collide with a project's root tasks, so there's
no core/no-project split and no hidden-desc bookkeeping. Other names
(`:self`, `:recipes` at the root, ...) stay free for Hammerfiles. The
`h:` subclass is flagged `@builtin_namespace`, which prunes it from the
compact listing - the built-ins are always dispatchable but only show
(under an `h:` section) in the extended `--help` view.

Task contracts:

* `:default` - hidden (no desc), at the root. Prints
  `self.class.root.print_help` (brief) and exposes a `--version` flag.
  Fires for bare `hammer` and leading-flag invocations where the first
  token starts with `-` and isn't `-h` / `--help` (see
  `Hammer.dispatch`). User overrides typically declare flag opts and
  fall through to `hammer :help` when none matched.
* `h:help` - has a desc; shows in the `--help` listing. Calls
  `self.class.root.print_help(opts[:args].first, extended: true)`. The
  conventional `help` / `-h` / `--help` at the top level still reach it
  (handled directly in `Hammer.dispatch`).
* `h:update` / `h:agents` / `h:version` - thin wrappers around
  `Hammer.self_update` / `Hammer.print_ai_help` / `puts Hammer::VERSION`.
* `h:recipes` - all recipe-management actions on one task, picked via
  boolean opts: `--install [NAME [TARGET]]`, `--show NAME`,
  `--path NAME`, `--edit NAME`, `--run NAME [ARGS]` (use `--` to
  forward flags through). Bare invocation lists.
* `h:init` - writes `Hammer::STARTER_HAMMERFILE` to `./Hammerfile`;
  refuses if one exists.
* `h:json` - `puts JSON` of `root.export_spec` (tasks grouped exactly
  like the bare listing via `section_for`, root group keyed `__root`).
  `--all` keeps the `h:` tree, `--compact` minifies.

The `:default` task and the `help` / `-h` / `--help` requests are
invoked via `run_command(cmd, argv, full: name, quiet: true)` - the
gray `> prog cmd ...` banner is suppressed because the user didn't type
`hammer default` / `hammer h:help` literally.
* Commands listed flat with colon paths, grouped by top-level namespace.
* Bare namespace (`hammer db`) prints the same listing scoped to that
  namespace.
* Per-command help: usage line shows declared opts inline (required
  bare, optional bracketed), then options with `(default: ...)` /
  `(required)` annotations, then examples.

## Inline helpers (`Hammer::Shell`)

Mixed into every handler. Also callable directly as `Hammer::Shell.<x>`.
Complete surface:

```ruby
say 'plain'                          # print
say.green 'ok'                       # colored via proxy (preferred form)
say 'ok', :green                     # equivalent two-arg form
say ''                               # blank line (NOT `say` with no args)

'OK'.color(:green)                   # paint without printing
Hammer::Shell.paint('x', :red)       # the underlying primitive

error 'config missing' unless ok     # raise Hammer::Error -> dispatcher exits 1
name = ask 'name'                    # read line
env  = ask 'env', default: 'dev'     # blank input -> default
exit 0 unless yes? 'continue?'       # y/Y prefix -> true, else false
idx = choose 'Pick env', envs        # arrow-key picker, returns Integer or nil
sh 'bundle install'                  # echo "$ cmd" gray, raise on non-zero

Hammer::Shell.color!(true|false)     # force ANSI on/off
Hammer::Shell.color?                 # current state
Hammer::Shell.print_error 'msg'      # stderr, no raise - dispatcher-only
```

Doc rule: prefer `say.<color> 'x'` over `say 'x', :<color>` in README
and examples - both work, but the proxy form reads better and is what
new code in this gem should show.

`choose` invariants worth knowing:

* Uses `io/console` (stdlib, no new dependency).
* TTY path renders the list, redraws on each keystroke (`\e[NA\e[J`),
  hides/restores the cursor, and reads bytes via `$stdin.raw { ... }`.
* Keys: `j`/`k` and arrow keys (ESC `[` `A`/`B`) move; Enter confirms;
  `q`, ESC alone, and Ctrl-C cancel. ESC-vs-arrow is disambiguated with
  a tiny `IO.select` timeout - the arrow's `[A` follows ESC immediately,
  a bare ESC keystroke is alone.
* Non-TTY path (`!$stdin.tty?` or stdin without `raw`) prints a numbered
  list and reads one line. Both paths return the same: `Integer` index
  or `nil`. Don't break this contract - it's why `choose` is scriptable.
* On confirm, the rendered list is collapsed to one green line; on
  cancel, the list is cleared. Don't leave the raw-mode list behind.
* Empty `items` raises `Hammer::Error` ('at least one item') - same
  failure pattern as bad colors.

## Colors

* Color set: `:black :red :green :yellow :blue :magenta :cyan :white :gray`
  (see `Hammer::Shell::COLORS`). No bold, no bright variants, no
  background colors. Don't add more without an explicit ask.
* All four entry points (`say x, :c`, `say.c x`, `paint x, :c`,
  `'x'.color(:c)`) flow through `Shell.paint` - it's the only place
  ANSI codes live.
* Unknown colors must raise `Hammer::Error` with the list of valid
  names. This is enforced in `Shell.paint` and in `SayProxy#method_missing`
  - don't bypass it. Validation runs even when colors are disabled, so
  a typo fails loudly in CI.
* `say` with no args returns the `SayProxy`; `say ''` is how you print
  a blank line. Don't restore `say` (no args) -> blank-line semantics.

## Error handling

* `Hammer::Shell.error 'msg'` raises `Hammer::Error`. The dispatcher
  catches it inside `run_command`, prints `[error] msg` in red to
  stderr, and exits 1 - no backtrace, no per-command help.
* `Hammer::Shell.print_error 'msg'` prints without raising; reserved
  for the dispatcher's own diagnostics (unknown command, missing
  Hammerfile).
* `Hammer::Parser::Error` is also caught in `run_command` and
  additionally prints per-command help (because the input *was* aimed
  at that command).
* Inside a handler, just call `error 'msg'` - it resolves via the
  `Shell` mixin.

## Coding rules

* No trailing spaces on empty lines. End every file with a newline.
* Use ASCII only - `-`, not unicode dashes; `*` for bullets in docs.
* Preserve existing style. Minimize diff size.
* Comments only when the *why* is non-obvious. Don't restate the code.
* No `// removed` markers - delete cleanly.
* Constants: prefer `FOO ||=` over `FOO =` (re-load safety).
* Never commit or push without explicit confirmation.

## Testing

* Run: `bundle exec rake test`
* Single file: `bundle exec ruby -Ilib -Itest test/parser_test.rb`
* Single test by name: `... test/parser_test.rb -n test_boolean_via_short_alias`
* Helper `CaptureIO` in `test/test_helper.rb` swaps `$stdout`/`$stderr`
  for `StringIO`. Use `capture { ... }` for non-exiting code and
  `capture_exit { ... }` for code that calls `exit`.

When you add a feature, add a test in the matching `_test.rb`. When you
fix a bug, write the failing test first.

## What NOT to do

* Don't add generators / templates (Thor-style file scaffolding).
* Don't add shell-completion generation to core - that belongs in a
  separate plugin gem.
* Don't introduce a class hierarchy for commands. Commands are data
  (`Hammer::Command` instances), not classes.
* Don't reintroduce a user-facing `program` / `program_name` setter -
  the auto-detected name is the whole API and was deliberately reduced
  to that.
* Don't propagate `program_name` into namespaces as a longer prefix -
  there is only one program name.
* Don't make `desc` multi-arg again (it once took `usage, description`
  - that was reverted intentionally).
* Don't add a `subcommand 'name', SomeClass` form - it was replaced by
  `namespace :name do ... end` intentionally.
* Don't auto-namespace fragments by filename (e.g. `db_hammer.rb` does
  not implicitly wrap in `namespace :db do ... end`). Be explicit, as
  Rake's `import` is. If a fragment wants a namespace, it writes it.

## When in doubt

* Read `lib/lux-hammer.rb` top-to-bottom. It's the whole DSL surface.
* Run the example: `cd examples && ruby -I../lib ../bin/hammer`
* Check `test/dsl_test.rb` for the canonical behavior of each feature.
* Check `test/load_test.rb` for `load` / fragment loader behavior.

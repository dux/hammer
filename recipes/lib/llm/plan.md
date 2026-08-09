# llm plan

Applies a /plan bundle: the edits decided during planning, replayed in one
call, with anything that moved on handed back to the agent instead of being
force-written.

## Why

Planning is slow and careful; applying should be neither. A plan already knows
the exact old/new text for every file, so "go" has no thinking left to do - it
should be one command, not twenty tool calls. The only real risk is that a file
changed between planning and applying, and that is what the sha1 is for.

## Flow

    /plan             decide everything, write ./tmp/plan-[SLUG].json
    llm plan:apply    sha1-check, write, run verify          <- one call
    drift?            agent finishes the few that moved on, then plan:verify
    you test          llm plan:revert if it is wrong
    git commit -F ./tmp/plan-[SLUG].msg                      <- only if you say so

## The bundle

    { "slug": "note-anchor",
      "goal":   "one line, why this change exists",
      "commit": { "subject": "...", "body": "..." },
      "verify": ["bundle exec rspec spec/note_spec.rb"],
      "files": [
        { "path": "./a.rb", "op": "create", "content": "..." },
        { "path": "./b.rb", "op": "change", "sha1": "<shasum at plan time>",
          "hunks": [{ "intent": "why", "old": "...", "new": "...", "all": false }] },
        { "path": "./c.rb", "op": "delete", "sha1": "<shasum at plan time>" }
      ] }

* `path`    project-relative, inside the tree, never a symlink
* `op`      create | change | delete
* `sha1`    `shasum <path>` at plan time; change and delete only - a create is
            checked as "must not exist"
* `hunks`   `old` must appear exactly once, unless `"all": true`
* `intent`  one line, printed when that file drifts and a human finishes it
* `note`    the file's clause in the summary. A change falls back to its hunk
            intents, so usually only creates and deletes need one
* `verify`  commands that prove the change; run only when nothing drifted

## Summary

`llm plan:check` is the screen to read before approving a plan. It groups the
files as Created / Changed / Deleted, sorts each group by path, and gives every
file one clause saying what will be done to it, plus `+X -Y` lines. Counts are
multiset-wise: a line that only moved counts as neither.

It also resolves every anchor against the real file without writing anything,
so a hunk that matches twice or not at all is caught while the plan can still
be fixed, instead of at apply time.

    Created
      ./app/Views/NoteAnchor.swift    anchor model + line resolution        +12 -0

    Changed
      ./app/Resources/preview.js      emit note-jump event on click         +8 -2
      ./app/Views/EditorPane.swift    route note taps through NoteAnchor    +3 -3

    Deleted
      ./app/Views/LegacyJump.swift    folded into NoteAnchor                +0 -40

    verify: swift build, swift test --filter NoteAnchorTests
    4 files, +23 -45, anchors resolve

Group headings are coloured by operation, paths cyan, `+` green and `-` red.

`--md` emits the same manifest for an agent to paste into a reply: the goal in
bold, then the files in a ```diff fence signed `+` created, `!` changed, `-`
deleted, so the renderer colours each row. Pair it with `HAMMER_QUIET=1` so the
`> llm ...` banner stays out of what gets pasted. The bundle itself is never
shown: it is a machine artifact, and reading JSON is not how anyone approves a
change.

## Drift

A file whose sha1 no longer matches is not written. It is printed with its
intent and its wanted old/new text, for the agent to apply by judgement against
the current file. That is the normal path, not an error.

## Exit codes

    0   applied, verify green
    10  drift - the output names each file, why, and the wanted old/new
    20  verify failed
    1   bad bundle: missing, malformed, or invalid

## Guarantees

* a file is written only once every hunk in it resolves - never half-edited
* writes are temp file + rename, keeping the original mode
* every touched file is copied to `<slug>.bak/` first, and the undo log is
  flushed per file, so an interrupted run is still revertible
* re-running a bundle that already landed is a no-op, not false drift
* verify never runs on a partially applied tree
* it never commits

## Side files, next to the bundle

    plan-[SLUG].bak/   pre-images + _applied.json (undo log)
    plan-[SLUG].msg    commit message, for git commit -F

## Gotchas

* namespaced commands need the colon: `llm plan:apply`, not `llm plan apply`
* run from the project root - bundle paths resolve against the cwd
* redirect stdin from an agent or script: `... < /dev/null`
  (hammer reads piped stdin and blocks on a pipe nobody closes)

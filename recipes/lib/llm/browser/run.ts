// CLI behind `llm browser:run` and `llm browser:script`.
//
//   bun run.ts <url> ["act: ..."] ["observe: ..."] ["extract: ..."] [--llm claude|codex|ollama] [--headed] [--shot out.png]
//   bun run.ts --script file.ts [args...]
//
// Instructions run in order on the same page; a bare instruction is an
// extract. One JSON object per instruction goes to stdout, progress to stderr.

import { open, LLMS, type Llm } from "./lib.ts";

type Op = "act" | "observe" | "extract";
type Instruction = { op: Op; text: string };

function usage(message?: string): never {
  if (message) console.error(`error: ${message}`);
  console.error(
    [
      "usage: run.ts <url> [instruction...] [--llm claude|codex|ollama] [--headed] [--shot out.png]",
      "       run.ts --script file.ts [args...]",
      '',
      'instructions: "act: click Sign in"  "observe: what can be clicked"  "extract: title and price"',
      "              a bare instruction is an extract",
    ].join("\n"),
  );
  process.exit(2);
}

function parseInstruction(raw: string): Instruction {
  const match = raw.match(/^(act|observe|extract)\s*:\s*(.*)$/is);
  return match ? { op: match[1].toLowerCase() as Op, text: match[2].trim() } : { op: "extract", text: raw.trim() };
}

function parseArgs(argv: string[]) {
  let url: string | undefined;
  let script: string | undefined;
  let llm: Llm = "claude";
  let headed = false;
  let shot: string | undefined;
  const instructions: Instruction[] = [];
  const rest: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--headed") headed = true;
    else if (arg === "--llm") llm = (argv[++i] ?? usage("--llm needs a value")) as Llm;
    else if (arg === "--shot") shot = argv[++i] ?? usage("--shot needs a path");
    else if (arg === "--script") script = argv[++i] ?? usage("--script needs a file");
    else if (arg === "-h" || arg === "--help") usage();
    else if (script) rest.push(arg);
    else if (!url) url = arg;
    else instructions.push(parseInstruction(arg));
  }
  if (!LLMS.includes(llm)) usage(`unknown llm ${llm} - one of ${LLMS.join(", ")}`);
  if (!script && !url) usage();
  return { url, script, llm, headed, shot, instructions, rest };
}

async function runInstructions(args: ReturnType<typeof parseArgs>) {
  const url = args.url!;
  const started = Date.now();
  const log = (line: string) => console.error(`[${((Date.now() - started) / 1000).toFixed(1)}s] ${line}`);

  log(`opening ${url} (llm: ${args.llm}${args.headed ? ", headed" : ""})`);
  const { stagehand, page, close } = await open({ headed: args.headed, llm: args.llm });
  const stop = async (code: number) => {
    await close();
    process.exit(code);
  };
  process.once("SIGINT", () => void stop(130));
  process.once("SIGTERM", () => void stop(143));

  let failed = false;
  try {
    await page.goto(url, { waitUntil: "load" });
    if (args.instructions.length === 0) log("no instructions - page loaded");

    for (const { op, text } of args.instructions) {
      log(`${op}: ${text}`);
      try {
        let data: unknown;
        if (op === "act") data = await stagehand.act(text);
        else if (op === "observe") data = await stagehand.observe(text);
        else data = (await stagehand.extract(text)).data;
        console.log(JSON.stringify({ op, instruction: text, data }));
      } catch (error) {
        failed = true;
        const message = error instanceof Error ? error.message : String(error);
        console.log(JSON.stringify({ op, instruction: text, error: message }));
        log(`failed: ${message}`);
        break;
      }
    }

    if (args.shot) {
      await Bun.write(args.shot, await page.screenshot({ type: "png" }));
      log(`screenshot: ${args.shot}`);
    }
    log(`done at ${await page.url()}`);
  } finally {
    await close();
  }
  process.exit(failed ? 1 : 0);
}

const args = parseArgs(process.argv.slice(2));
if (args.script) {
  process.argv = [process.argv[0], args.script, ...args.rest];
  await import(args.script);
} else {
  await runInstructions(args);
}

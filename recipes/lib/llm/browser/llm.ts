// Stagehand "bring your own LLM" callbacks that answer through the claude or
// codex CLI, so act / observe / extract run on the subscription instead of an
// API key. Each call spawns the CLI once (a few seconds); Stagehand makes one
// to three calls per action.
//
// Contract (Stagehand v4 ClientLLMSchema): generate(params) receives
// { messages, systemPrompt?, temperature?, responseFormat? } and answers with
// { role: "assistant", content: { type: "text", text }, outputFormat, structuredContent? }.

import { mkdtemp, rm, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type Backend = "claude" | "codex" | "ollama";

type TextBlock = { type: "text"; text: string };
type ImageBlock = { type: "image"; data: string; mimeType: string };
type Block = TextBlock | ImageBlock | { type: string; [key: string]: unknown };

export type GenerateParams = {
  messages: Array<{ role: string; content: Block | Block[] }>;
  systemPrompt?: string;
  temperature?: number;
  responseFormat?: { type: "text" } | { type: "json_schema"; name: string; schema: unknown };
};

export type GenerateResult = {
  role: "assistant";
  content: { type: "text"; text: string };
  outputFormat: "text" | "json_schema";
  structuredContent?: unknown;
};

// sonnet: haiku found "no actionable element" on one of two runs of a plain
// link click; sonnet took both.
const CLAUDE_MODEL = process.env.BROWSE_CLAUDE_MODEL ?? "sonnet";
const CODEX_MODEL = process.env.BROWSE_CODEX_MODEL;
const OLLAMA_MODEL = process.env.BROWSE_OLLAMA_MODEL ?? "qwen2.5-coder";
const OLLAMA_URL = process.env.OLLAMA_HOST ?? "http://127.0.0.1:11434";
const DEBUG = !!process.env.BROWSE_DEBUG;

const BACKENDS: Record<Backend, (params: GenerateParams) => Promise<GenerateResult>> = {
  claude: generateWithClaude,
  codex: generateWithCodex,
  ollama: generateWithOllama,
};

export function makeGenerate(backend: Backend): (params: GenerateParams) => Promise<GenerateResult> {
  return BACKENDS[backend];
}

// Stagehand sends a short conversation; the CLIs take one prompt. Flatten it
// role by role and park any image blocks on disk for the CLI to pick up.
async function flatten(params: GenerateParams, dir: string) {
  const images: string[] = [];
  const parts: string[] = [];
  for (const message of params.messages) {
    const blocks = Array.isArray(message.content) ? message.content : [message.content];
    const lines: string[] = [];
    for (const block of blocks) {
      if (block.type === "text") {
        lines.push((block as TextBlock).text);
      } else if (block.type === "image") {
        const image = block as ImageBlock;
        const ext = image.mimeType.split("/")[1] ?? "png";
        const path = join(dir, `image-${images.length + 1}.${ext}`);
        await writeFile(path, Buffer.from(image.data, "base64"));
        images.push(path);
        lines.push(`[attached image: ${path}]`);
      } else {
        lines.push(JSON.stringify(block));
      }
    }
    parts.push(`${message.role}:\n${lines.join("\n")}`);
  }
  return { prompt: parts.join("\n\n"), images };
}

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(join(tmpdir(), "llm-browser-"));
  try {
    return await fn(dir);
  } finally {
    if (!DEBUG) await rm(dir, { recursive: true, force: true });
  }
}

async function spawn(argv: string[], stdin: string, cwd?: string) {
  if (DEBUG) console.error(`[llm] ${argv.join(" ")}`);
  const started = Date.now();
  const proc = Bun.spawn(argv, {
    cwd,
    stdin: new Response(stdin),
    stdout: "pipe",
    stderr: "pipe",
    // A nested `claude -p` refuses to start when it thinks it is inside
    // Claude Code; the shim is not that.
    env: { ...process.env, CLAUDECODE: undefined, CLAUDE_CODE_ENTRYPOINT: undefined },
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (DEBUG) console.error(`[llm] exit ${code} in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  if (code !== 0) throw new Error(`${argv[0]} exited ${code}: ${stderr.trim() || stdout.trim()}`);
  return stdout;
}

function parseJson(text: string): unknown {
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return JSON.parse(trimmed);
  } catch {
    const start = trimmed.indexOf("{");
    const end = trimmed.lastIndexOf("}");
    if (start >= 0 && end > start) return JSON.parse(trimmed.slice(start, end + 1));
    throw new Error(`model did not return JSON: ${trimmed.slice(0, 200)}`);
  }
}

// Stagehand stamps `$schema: draft/2020-12` on its schemas; the CLIs'
// validators know draft-07 and reject the header outright.
function schemaFor(params: GenerateParams): string {
  const { $schema: _drop, $id: _id, ...schema } = (params.responseFormat as { schema: Record<string, unknown> }).schema;
  return JSON.stringify(schema);
}

function result(text: string, structured?: unknown): GenerateResult {
  return structured === undefined
    ? { role: "assistant", content: { type: "text", text }, outputFormat: "text" }
    : { role: "assistant", content: { type: "text", text }, outputFormat: "json_schema", structuredContent: structured };
}

async function generateWithClaude(params: GenerateParams): Promise<GenerateResult> {
  return withTempDir(async (dir) => {
    const { prompt, images } = await flatten(params, dir);
    const structured = params.responseFormat?.type === "json_schema";
    // Not --bare: that skips keychain reads and the CLI reports "not logged in".
    // Only project settings, read from the empty temp dir: user-level hooks
    // (the prompt-token expander) and CLAUDE.md stay out of the exchange.
    const argv = [
      "claude", "-p", "--no-session-persistence",
      "--setting-sources", "project",
      "--output-format", "json",
      "--model", CLAUDE_MODEL,
      "--system-prompt", params.systemPrompt ?? "You are a precise browser-automation assistant.",
    ];
    // No tools unless there is an image to look at.
    argv.push("--tools", images.length ? "Read" : "");
    if (images.length) argv.push("--add-dir", dir);
    if (structured) argv.push("--json-schema", schemaFor(params));
    const raw = await spawn(argv, prompt, dir);
    // `--output-format json` prints the message list; the last `result` entry
    // carries the text and, with --json-schema, structured_output.
    type Envelope = { type?: string; result?: string; structured_output?: unknown; is_error?: boolean };
    const parsed = parseJson(raw);
    const messages = (Array.isArray(parsed) ? parsed : [parsed]) as Envelope[];
    const envelope = messages.filter((m) => m.type === "result").at(-1) ?? messages.at(-1);
    if (!envelope) throw new Error("claude: empty output");
    if (envelope.is_error) throw new Error(`claude: ${envelope.result}`);
    const text = envelope.result ?? "";
    if (!structured) return result(text);
    return result(text, envelope.structured_output ?? parseJson(text));
  });
}

// Stagehand v4 validates modelName against a fixed provider list that has no
// ollama entry, so the local daemon goes through the callback too. Its chat
// API takes a JSON schema as `format` and returns conforming JSON.
async function generateWithOllama(params: GenerateParams): Promise<GenerateResult> {
  const structured = params.responseFormat?.type === "json_schema";
  const messages: Array<{ role: string; content: string; images?: string[] }> = [];
  if (params.systemPrompt) messages.push({ role: "system", content: params.systemPrompt });
  for (const message of params.messages) {
    const blocks = Array.isArray(message.content) ? message.content : [message.content];
    const text = blocks.filter((b) => b.type === "text").map((b) => (b as TextBlock).text).join("\n");
    const images = blocks.filter((b) => b.type === "image").map((b) => (b as ImageBlock).data);
    messages.push({ role: message.role, content: text, ...(images.length ? { images } : {}) });
  }
  const body = {
    model: OLLAMA_MODEL,
    messages,
    stream: false,
    options: { temperature: params.temperature ?? 0 },
    ...(structured ? { format: JSON.parse(schemaFor(params)) } : {}),
  };
  if (DEBUG) console.error(`[llm] POST ${OLLAMA_URL}/api/chat model=${OLLAMA_MODEL}`);
  const started = Date.now();
  const response = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`ollama ${response.status}: ${(await response.text()).slice(0, 300)}`);
  const data = (await response.json()) as { message?: { content?: string } };
  if (DEBUG) console.error(`[llm] ollama answered in ${((Date.now() - started) / 1000).toFixed(1)}s`);
  const text = data.message?.content ?? "";
  return structured ? result(text, parseJson(text)) : result(text);
}

async function generateWithCodex(params: GenerateParams): Promise<GenerateResult> {
  return withTempDir(async (dir) => {
    const { prompt, images } = await flatten(params, dir);
    const structured = params.responseFormat?.type === "json_schema";
    const out = join(dir, "last.txt");
    const argv = [
      "codex", "exec", "--skip-git-repo-check", "--ephemeral",
      "-s", "read-only", "--color", "never", "-C", dir, "-o", out,
    ];
    if (CODEX_MODEL) argv.push("-m", CODEX_MODEL);
    for (const image of images) argv.push("-i", image);
    if (structured) {
      const schema = join(dir, "schema.json");
      await writeFile(schema, schemaFor(params));
      argv.push("--output-schema", schema);
    }
    argv.push("-");
    const system = params.systemPrompt ? `${params.systemPrompt}\n\n` : "";
    await spawn(argv, `${system}${prompt}`);
    const text = (await readFile(out, "utf8")).trim();
    return structured ? result(text, parseJson(text)) : result(text);
  });
}

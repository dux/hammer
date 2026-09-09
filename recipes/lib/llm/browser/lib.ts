// open() - a Stagehand instance on the local Chrome, thinking through the
// chosen backend. Ad-hoc scripts (`llm browser:script file.ts`) import this:
//
//   import { open } from "<lux-hammer>/recipes/lib/llm/browser/lib.ts";
//   const { stagehand, page, close } = await open({ headed: true });
//   try { await page.goto("https://..."); await stagehand.act("..."); } finally { await close(); }

import { existsSync } from "node:fs";
import { Stagehand, localBrowser } from "@browserbasehq/stagehand";
import { makeGenerate, type Backend } from "./llm.ts";

export type Llm = Backend;
export const LLMS: Llm[] = ["claude", "codex", "ollama"];

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

export type OpenOptions = { headed?: boolean; llm?: Llm };

export async function open({ headed = false, llm = "claude" }: OpenOptions = {}) {
  if (!LLMS.includes(llm)) throw new Error(`unknown llm ${llm} - one of ${LLMS.join(", ")}`);

  const browser = await localBrowser.launch({
    headless: !headed,
    ...(existsSync(CHROME) ? { executablePath: CHROME } : {}),
  });

  let stagehand: Stagehand;
  try {
    // Every backend is a client-side generate callback; Stagehand validates
    // its shape at runtime (ClientLLMSchema).
    stagehand = await Stagehand.create({ browser, model: { generate: makeGenerate(llm) } as never });
  } catch (error) {
    await browser.close().catch(() => {});
    throw error;
  }

  const context = stagehand.browser.context;
  const page = (await context.activePage()) ?? (await context.newPage());

  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    await stagehand.close().catch(() => {});
    await browser.close().catch(() => {});
  };

  return { stagehand, browser, page, close };
}

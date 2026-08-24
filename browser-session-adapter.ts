import { randomUUID } from "crypto";
import type { Express, NextFunction, Request, Response } from "express";
import type { Browser, BrowserContext, Locator, Page } from "playwright";

type ContextBundle = {
  context: BrowserContext;
};

type Session = {
  id: string;
  context: BrowserContext;
  page: Page;
  refs: Map<string, Locator>;
  createdAt: number;
  expiresAt: number;
  baseUrl: string;
  timer: NodeJS.Timeout;
};

type AdapterDependencies = {
  getBrowser: () => Browser;
  createContext: () => Promise<ContextBundle>;
  acquire: () => Promise<void>;
  release: () => void;
  publicBaseUrl?: string;
};

const MAX_COMMAND_LENGTH = 100_000;
const MAX_SNAPSHOT_ELEMENTS = 100;
const MAX_VIEW_HTML = 1_000_000;

function splitShellChain(command: string): string[] {
  const parts: string[] = [];
  let current = "";
  let quote: string | null = null;
  let escaped = false;

  for (let i = 0; i < command.length; i += 1) {
    const char = command[i];
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === "\\" && quote !== "'") {
      current += char;
      escaped = true;
      continue;
    }
    if (quote) {
      current += char;
      if (char === quote) quote = null;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      current += char;
      continue;
    }
    if (char === "&" && command[i + 1] === "&") {
      if (current.trim()) parts.push(current.trim());
      current = "";
      i += 1;
      continue;
    }
    current += char;
  }

  if (current.trim()) parts.push(current.trim());
  return parts;
}

function tokenize(command: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let quote: string | null = null;
  let escaped = false;

  const push = () => {
    if (current.length > 0) tokens.push(current);
    current = "";
  };

  for (const char of command.trim()) {
    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }
    if (char === "\\" && quote !== "'") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (char === quote) quote = null;
      else current += char;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
    } else if (/\s/.test(char)) {
      push();
    } else {
      current += char;
    }
  }
  if (escaped) current += "\\";
  push();
  return tokens;
}

function outputText(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function htmlEscape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function sessionBaseUrl(deps: AdapterDependencies): string {
  return (deps.publicBaseUrl || "http://playwright-service:3000").replace(
    /\/+$/,
    "",
  );
}

function authorized(req: Request): boolean {
  const expected = process.env.BROWSER_SERVICE_API_KEY?.trim();
  return !expected || req.headers.authorization === `Bearer ${expected}`;
}

function requireAdapterAuth(
  req: Request,
  res: Response,
  next: NextFunction,
): void {
  if (authorized(req)) next();
  else res.status(401).json({ error: "Browser service authorization required" });
}

function locatorFor(page: Page, refs: Map<string, Locator>, selector: string) {
  return selector.startsWith("@") && refs.has(selector)
    ? refs.get(selector)!
    : page.locator(selector);
}

async function runLocatorAction(
  locator: Locator,
  action: string,
  value?: string,
): Promise<unknown> {
  switch (action) {
    case "click":
      await locator.click();
      return "";
    case "dblclick":
      await locator.dblclick();
      return "";
    case "fill":
      await locator.fill(value ?? "");
      return "";
    case "type":
      await locator.pressSequentially(value ?? "");
      return "";
    case "hover":
      await locator.hover();
      return "";
    case "check":
      await locator.check();
      return "";
    case "uncheck":
      await locator.uncheck();
      return "";
    case "text":
      return await locator.innerText();
    case "html":
      return await locator.innerHTML();
    case "value":
      return await locator.inputValue();
    default:
      throw new Error(`Unsupported element action: ${action}`);
  }
}

async function snapshot(session: Session): Promise<string> {
  session.refs.clear();
  const lines = [`URL: ${session.page.url()}`];
  const selector =
    "a,button,input,textarea,select,[role=button],[role=link],[role=textbox]";
  const count = Math.min(
    await session.page.locator(selector).count(),
    MAX_SNAPSHOT_ELEMENTS,
  );

  for (let i = 0; i < count; i += 1) {
    const ref = `@e${i + 1}`;
    const locator = session.page.locator(selector).nth(i);
    session.refs.set(ref, locator);
    const tag = await locator.evaluate(element => element.tagName.toLowerCase());
    const role = (await locator.getAttribute("role")) || tag;
    const label =
      (await locator.getAttribute("aria-label")) ||
      (await locator.getAttribute("placeholder")) ||
      (await locator.innerText().catch(() => "")) ||
      (await locator.getAttribute("value")) ||
      "";
    lines.push(`${ref} <${role}> ${label.trim().replace(/\s+/g, " ")}`);
  }
  return lines.join("\n");
}

async function runAgentCommand(session: Session, command: string): Promise<string> {
  const tokens = tokenize(command);
  if (tokens[0] !== "agent-browser") {
    throw new Error("Only agent-browser commands are allowed");
  }

  const operation = tokens[1];
  if (!operation) throw new Error("Missing agent-browser command");

  if (operation === "snapshot") return snapshot(session);
  if (operation === "goto" || operation === "open") {
    const target = tokens.slice(2).join(" ");
    const parsed = new URL(target);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error("Browser navigation requires an HTTP(S) URL");
    }
    await session.page.goto(parsed.href, { waitUntil: "networkidle" });
    return "";
  }
  if (operation === "back") {
    await session.page.goBack();
    return "";
  }
  if (operation === "reload") {
    await session.page.reload();
    return "";
  }
  if (operation === "get") {
    const kind = tokens[2];
    if (kind === "url") return session.page.url();
    if (kind === "title") return session.page.title();
    if (kind === "cdp-url") return `${session.baseUrl}/browsers/${session.id}/cdp`;
    if (kind === "count") return String(await session.page.locator(tokens[3]).count());
    if (kind === "text") {
      const target = tokens[3] || "body";
      return String(await locatorFor(session.page, session.refs, target).innerText());
    }
    if (kind === "html") {
      const target = tokens[3] || "body";
      return String(await locatorFor(session.page, session.refs, target).innerHTML());
    }
    if (kind === "value") {
      return String(await locatorFor(session.page, session.refs, tokens[3]).inputValue());
    }
    throw new Error(`Unsupported get command: ${kind}`);
  }
  if (operation === "eval") {
    const script = tokens.slice(2).join(" ");
    return outputText(await session.page.evaluate(script));
  }
  if (operation === "press") {
    await session.page.keyboard.press(tokens.slice(2).join(" "));
    return "";
  }
  if (operation === "keyboard" && tokens[2] === "type") {
    await session.page.keyboard.type(tokens.slice(3).join(" "));
    return "";
  }
  if (operation === "scroll") {
    const direction = tokens[2] === "up" ? -800 : 800;
    await session.page.mouse.wheel(0, direction);
    return "";
  }
  if (operation === "wait") {
    if (/^\d+$/.test(tokens[2] || "")) {
      await session.page.waitForTimeout(Number(tokens[2]));
    } else if (tokens[2] === "--load") {
      await session.page.waitForLoadState((tokens[3] || "load") as any);
    } else if (tokens[2] === "--text") {
      await session.page.getByText(tokens.slice(3).join(" ")).first().waitFor();
    } else if (tokens[2] === "--fn") {
      await session.page.waitForFunction(tokens.slice(3).join(" "));
    } else {
      await session.page.waitForSelector(tokens[2]);
    }
    return "";
  }
  if (operation === "find") {
    const kind = tokens[2];
    const query = tokens[3];
    const action = tokens[4];
    let locator: Locator;
    if (kind === "role") {
      const nameIndex = tokens.indexOf("--name");
      const name = nameIndex >= 0 ? tokens.slice(nameIndex + 1).join(" ") : undefined;
      locator = session.page.getByRole(query as any, name ? { name } : undefined).first();
    } else if (kind === "text") {
      locator = session.page.getByText(query).first();
    } else if (kind === "placeholder") {
      locator = session.page.getByPlaceholder(query).first();
    } else if (kind === "label") {
      locator = session.page.getByLabel(query).first();
    } else {
      throw new Error(`Unsupported find command: ${kind}`);
    }
    return outputText(await runLocatorAction(locator, action, tokens.slice(5).join(" ")));
  }

  const selector = tokens[2];
  const locator = locatorFor(session.page, session.refs, selector);
  if (operation === "click" || operation === "dblclick" || operation === "fill" || operation === "type" || operation === "hover" || operation === "check" || operation === "uncheck") {
    return outputText(await runLocatorAction(locator, operation, tokens.slice(3).join(" ")));
  }
  if (operation === "screenshot") {
    if (tokens[2]) throw new Error("Saving screenshots to a server path is not supported");
    await session.page.screenshot();
    return "screenshot captured";
  }
  if (operation === "frame") throw new Error("Frame switching is not supported by the local adapter");
  throw new Error(`Unsupported agent-browser command: ${operation}`);
}

async function executeBash(session: Session, code: string): Promise<string> {
  let output = "";
  for (const command of splitShellChain(code)) {
    output = await runAgentCommand(session, command);
  }
  return output;
}

export function installBrowserSessionRoutes(
  app: Express,
  deps: AdapterDependencies,
): void {
  const sessions = new Map<string, Session>();

  const destroy = async (id: string): Promise<number> => {
    const session = sessions.get(id);
    if (!session) return 0;
    sessions.delete(id);
    clearTimeout(session.timer);
    const durationMs = Math.max(0, Date.now() - session.createdAt);
    await session.context.close().catch(() => {});
    deps.release();
    return durationMs;
  };

  const findSession = (req: Request, res: Response): Session | null => {
    const session = sessions.get(String(req.params.id));
    if (!session) {
      res.status(404).json({ error: "Browser session not found" });
      return null;
    }
    return session;
  };

  app.use("/browsers", requireAdapterAuth);

  app.post("/browsers", async (req, res) => {
    const ttl = Math.min(Math.max(Number(req.body?.ttl) || 600, 30), 3600);
    await deps.acquire();
    let context: BrowserContext | undefined;
    try {
      const bundle = await deps.createContext();
      context = bundle.context;
      const page = await context.newPage();
      const id = randomUUID();
      const createdAt = Date.now();
      const expiresAt = createdAt + ttl * 1000;
      const timer = setTimeout(() => {
        void destroy(id);
      }, ttl * 1000);
      timer.unref();
      sessions.set(id, {
        id,
        context,
        page,
        refs: new Map(),
        createdAt,
        expiresAt,
        baseUrl: sessionBaseUrl(deps),
        timer,
      });
      const base = sessionBaseUrl(deps);
      return res.json({
        sessionId: id,
        cdpUrl: `${base}/browsers/${id}/cdp`,
        viewUrl: `${base}/browsers/${id}/view`,
        iframeUrl: `${base}/browsers/${id}/view`,
        interactiveIframeUrl: `${base}/browsers/${id}/view`,
        expiresAt: new Date(expiresAt).toISOString(),
      });
    } catch (error) {
      if (context) await context.close().catch(() => {});
      deps.release();
      return res.status(500).json({
        error: error instanceof Error ? error.message : "Failed to create browser session",
      });
    }
  });

  app.post("/browsers/:id/exec", async (req, res) => {
    const session = findSession(req, res);
    if (!session) return;
    const code = typeof req.body?.code === "string" ? req.body.code : "";
    const language = req.body?.language || "bash";
    const timeout = Math.min(Math.max(Number(req.body?.timeout) || 30, 1), 300) * 1000;
    if (!code || code.length > MAX_COMMAND_LENGTH) {
      return res.status(400).json({ error: "code is required and must be at most 100000 characters" });
    }

    let timer: NodeJS.Timeout | undefined;
    try {
      const execution = language === "bash"
        ? executeBash(session, code)
        : Promise.reject(new Error("The local adapter supports agent-browser bash commands only"));
      const timed = new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("Browser execution timed out")), timeout);
      });
      const value = await Promise.race([execution, timed]);
      return res.json({ stdout: value, result: value, stderr: "", exitCode: 0, killed: false });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const killed = message === "Browser execution timed out";
      return res.json({ stdout: "", result: "", stderr: message, exitCode: 1, killed });
    } finally {
      if (timer) clearTimeout(timer);
    }
  });

  app.delete("/browsers/:id", async (req, res) => {
    const session = sessions.get(req.params.id);
    if (!session) {
      return res.json({ ok: true, sessionDurationMs: 0, cleanupQueued: true });
    }
    const durationMs = await destroy(req.params.id);
    return res.json({ ok: true, sessionDurationMs: durationMs, cleanupQueued: true });
  });

  app.get("/browsers/:id/view", async (req, res) => {
    const session = findSession(req, res);
    if (!session) return;
    const title = await session.page.title().catch(() => "");
    const url = session.page.url();
    const content = (await session.page.content().catch(() => "")).slice(0, MAX_VIEW_HTML);
    res.type("html").send(
      `<!doctype html><meta charset="utf-8"><title>${htmlEscape(title)}</title><p>URL: ${htmlEscape(url)}</p>${content}`,
    );
  });
}

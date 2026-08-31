import { afterEach, describe, expect, it, vi } from "vitest";

import { OAuthRequestGuard, handleRequest, type Env } from "../src/index.js";

const env: Env = {
  GITHUB_OAUTH_CLIENT_ID: "client-id",
  GITHUB_OAUTH_CLIENT_SECRET: "client-secret",
  ALLOWED_REDIRECT_URI: "triage://oauth-callback",
  MINIMUM_APPLICATION_VERSION: "0.1.0",
  REQUEST_RATE_LIMIT_PER_MINUTE: "100",
  IP_RATE_LIMIT_PER_MINUTE: "10",
  REQUEST_CONTROL_HASH_KEY: "test-request-control-key-with-sufficient-length",
  OAUTH_REQUEST_GUARD: undefined as never,
};

const githubToken = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  token_type: "bearer",
  scope: "repo read:org",
  expires_in: 28_800,
  refresh_token_expires_in: 15_552_000,
};

let requestNumber = 0;

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function request(
  path: string,
  init: RequestInit = {},
): Request {
  return new Request(`https://broker.example${path}`, init);
}

function jsonRequest(path: string, body: unknown, init: RequestInit = {}): Request {
  const headers = new Headers(init.headers);
  headers.set("Content-Type", "application/json");
  if (!headers.has("CF-Connecting-IP")) {
    headers.set("CF-Connecting-IP", "203.0.113.1");
  }
  if (!headers.has("X-Triage-Application-Version")) {
    headers.set("X-Triage-Application-Version", "0.1.0");
  }
  return request(path, {
    ...init,
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function exchangeInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const issuedAt = Date.now();
  return {
    version: 1,
    authorizationCode: "authorization-code",
    codeVerifier: "a".repeat(43),
    redirectURI: "triage://oauth-callback",
    nonce: `n${++requestNumber}`.padEnd(43, "n"),
    issuedAt,
    expiresAt: issuedAt + 60_000,
    ...overrides,
  };
}

function refreshInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const issuedAt = Date.now();
  return {
    version: 1,
    refreshToken: "refresh-token",
    nonce: `r${++requestNumber}`.padEnd(43, "r"),
    issuedAt,
    expiresAt: issuedAt + 60_000,
    ...overrides,
  };
}

class InMemoryRequestGuard {
  private readonly consumedNonces = new Set<string>();

  idFromName(name: string): string {
    return name;
  }

  get(_id: string): { fetch: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> } {
    return {
      fetch: async (input, init) => {
        if (new URL(input.toString()).pathname === "/health") {
          return new Response(null, { status: 204 });
        }
        const payload = JSON.parse(init?.body as string) as { nonce: string };
        if (this.consumedNonces.has(payload.nonce)) {
          return new Response(null, { status: 409 });
        }
        this.consumedNonces.add(payload.nonce);
        return new Response(null, { status: 204 });
      },
    };
  }
}

env.OAUTH_REQUEST_GUARD = new InMemoryRequestGuard();

class GuardStorage {
  private readonly values = new Map<string, number>();
  readonly reads: string[] = [];
  alarm: number | undefined;

  async get<T>(key: string): Promise<T | undefined> {
    this.reads.push(key);
    return this.values.get(key) as T | undefined;
  }

  async put(entries: Record<string, number>): Promise<void> {
    for (const [key, value] of Object.entries(entries)) {
      this.values.set(key, value);
    }
  }

  async delete(key: string): Promise<boolean> {
    return this.values.delete(key);
  }

  async list<T>(): Promise<Map<string, T>> {
    return new Map(this.values) as Map<string, T>;
  }

  async setAlarm(timestamp: number): Promise<void> {
    this.alarm = timestamp;
  }

  async getAlarm(): Promise<number | null> {
    return this.alarm ?? null;
  }

  async transaction<T>(callback: (storage: GuardStorage) => Promise<T>): Promise<T> {
    return callback(this);
  }

  keys(): string[] {
    return [...this.values.keys()].sort();
  }
}

function guardRequest(body: unknown): Request {
  return new Request("https://request-guard/consume", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

describe("AuthBroker", () => {
  it("returns a no-store health response without calling GitHub", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(request("/health"), env);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ version: 1, status: "ok" });
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    expect(response.headers.get("strict-transport-security")).toContain("max-age=");
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("fails health closed when the request guard cannot be reached", async () => {
    const unavailableGuard: Env = {
      ...env,
      OAUTH_REQUEST_GUARD: {
        idFromName: () => "guard" as never,
        get: () => ({ fetch: async () => { throw new Error("guard unavailable"); } }),
      },
    };

    const response = await handleRequest(request("/health"), unavailableGuard);

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ version: 1, status: "unavailable" });
  });

  it("uses a benign Durable Object storage read for its health probe", async () => {
    const storage = new GuardStorage();
    const guard = new OAuthRequestGuard({ storage } as unknown as DurableObjectState, env);

    const response = await guard.fetch(new Request("https://request-guard/health"));

    expect(response.status).toBe(204);
    expect(storage.reads).toEqual(["health"]);
  });

  it("exchanges only validated input and maps GitHub's response to the app schema", async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json(githubToken));
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput()),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      version: 1,
      accessToken: "access-token",
      refreshToken: "refresh-token",
      tokenType: "bearer",
      scope: "repo read:org",
      expiresIn: 28_800,
      refreshTokenExpiresIn: 15_552_000,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://github.com/login/oauth/access_token");
    expect(init.method).toBe("POST");
    expect(init.redirect).toBe("error");
    expect(new Headers(init.headers).get("accept")).toBe("application/json");
    expect(new Headers(init.headers).get("content-type")).toBe(
      "application/x-www-form-urlencoded",
    );
    expect(new URLSearchParams(init.body as string)).toEqual(
      new URLSearchParams({
        client_id: "client-id",
        client_secret: "client-secret",
        code: "authorization-code",
        code_verifier: "a".repeat(43),
        redirect_uri: "triage://oauth-callback",
      }),
    );
  });

  it("refreshes a token with the explicit GitHub refresh grant", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      Response.json({ access_token: "replacement", token_type: "bearer" }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(
      jsonRequest("/oauth/refresh", refreshInput()),
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      version: 1,
      accessToken: "replacement",
      tokenType: "bearer",
    });
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(new URLSearchParams(init.body as string)).toEqual(
      new URLSearchParams({
        client_id: "client-id",
        client_secret: "client-secret",
        grant_type: "refresh_token",
        refresh_token: "refresh-token",
      }),
    );
  });

  it.each([
    ["wrong method", request("/oauth/exchange", { method: "GET" })],
    [
      "wrong content type",
      request("/oauth/exchange", { method: "POST", body: "{}", headers: { "Content-Type": "text/plain" } }),
    ],
    ["malformed JSON", request("/oauth/exchange", { method: "POST", body: "{", headers: { "Content-Type": "application/json" } })],
    ["unknown field", jsonRequest("/oauth/exchange", { ...exchangeInput(), extra: true })],
    ["wrong version", jsonRequest("/oauth/exchange", exchangeInput({ version: 2 }))],
    ["invalid PKCE length", jsonRequest("/oauth/exchange", exchangeInput({ codeVerifier: "a".repeat(42) }))],
    ["invalid PKCE character", jsonRequest("/oauth/exchange", exchangeInput({ codeVerifier: `${"a".repeat(42)}!` }))],
    ["different redirect URI", jsonRequest("/oauth/exchange", exchangeInput({ redirectURI: "triage://other" }))],
    ["cookie input", jsonRequest("/oauth/exchange", exchangeInput(), { headers: { Cookie: "session=ignored" } })],
  ])("rejects %s before forwarding", async (_name, invalidRequest) => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(invalidRequest, env);

    expect([400, 405]).toContain(response.status);
    expect(await response.json()).toMatchObject({ version: 1, code: "invalidRequest" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("enforces the 16 KiB request limit", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const response = await handleRequest(
      request("/oauth/exchange", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "x".repeat(16 * 1024 + 1),
      }),
      env,
    );

    expect(response.status).toBe(413);
    expect(await response.json()).toMatchObject({ code: "invalidRequest" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects unsupported application versions, invalid timestamps, and a repeated nonce before GitHub", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-31T00:00:00.000Z"));
    const fetchMock = vi.fn().mockResolvedValue(Response.json(githubToken));
    vi.stubGlobal("fetch", fetchMock);

    const unsupported = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput(), {
        headers: { "X-Triage-Application-Version": "0.0.9" },
      }),
      env,
    );
    expect(unsupported.status).toBe(400);

    const expiredAt = Date.now() - 1;
    const expired = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput({ issuedAt: expiredAt - 60_000, expiresAt: expiredAt })),
      env,
    );
    expect(expired.status).toBe(400);

    const now = Date.now();
    const futureIssued = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput({ issuedAt: now + 1, expiresAt: now + 60_001 })),
      env,
    );
    expect(futureIssued.status).toBe(400);

    const overlongLifetime = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput({ issuedAt: now, expiresAt: now + 60_001 })),
      env,
    );
    expect(overlongLifetime.status).toBe(400);

    const payload = exchangeInput();
    const first = await handleRequest(jsonRequest("/oauth/exchange", payload), env);
    const replay = await handleRequest(jsonRequest("/oauth/exchange", payload), env);
    expect(first.status).toBe(200);
    expect(replay.status).toBe(400);
    expect(await replay.json()).toMatchObject({ code: "invalidRequest" });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("fails closed when the request guard enforces a rate limit", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const rateLimitedEnv: Env = {
      ...env,
      OAUTH_REQUEST_GUARD: {
        idFromName: () => "guard" as never,
        get: () => ({ fetch: async () => new Response(null, { status: 429 }) }),
      },
    };

    const response = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput()),
      rateLimitedEnv,
    );

    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ code: "temporarilyUnavailable" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("atomically consumes one-use nonces and enforces one global minute rate limit across endpoints", async () => {
    const storage = new GuardStorage();
    const guard = new OAuthRequestGuard({ storage } as unknown as DurableObjectState, {
      ...env,
      REQUEST_RATE_LIMIT_PER_MINUTE: "1",
      IP_RATE_LIMIT_PER_MINUTE: "1",
    });
    const now = Date.now();
    const requestBody = {
      nonce: "g".repeat(43),
      expiresAt: now + 60_000,
      clientIP: "203.0.113.1",
      endpoint: "/oauth/exchange",
      now,
      requestRateLimitPerMinute: 1,
      ipRateLimitPerMinute: 1,
    };

    expect((await guard.fetch(guardRequest(requestBody))).status).toBe(204);
    expect((await guard.fetch(guardRequest(requestBody))).status).toBe(409);
    expect((await guard.fetch(guardRequest({
      ...requestBody,
      nonce: "h".repeat(43),
      clientIP: "2001:db8::2",
      endpoint: "/oauth/refresh",
    }))).status).toBe(429);
  });

  it("reclaims expired rate buckets and reschedules the alarm until every key is removed", async () => {
    vi.useFakeTimers();
    const now = Date.UTC(2026, 7, 31, 0, 0, 0, 1);
    vi.setSystemTime(now);
    const storage = new GuardStorage();
    const guard = new OAuthRequestGuard({ storage } as unknown as DurableObjectState, env);
    const requestBody = {
      nonce: "g".repeat(43),
      expiresAt: now + 60_000,
      clientIP: "203.0.113.1",
      endpoint: "/oauth/exchange",
      now,
      requestRateLimitPerMinute: 10,
      ipRateLimitPerMinute: 10,
    };

    expect((await guard.fetch(guardRequest(requestBody))).status).toBe(204);
    const rateExpiry = (Math.floor(now / 60_000) + 1) * 60_000;
    expect(storage.alarm).toBe(rateExpiry);

    vi.setSystemTime(rateExpiry);
    storage.alarm = undefined;
    await guard.alarm();
    expect(storage.keys()).toHaveLength(1);
    expect(storage.alarm).toBe(requestBody.expiresAt);

    vi.setSystemTime(requestBody.expiresAt);
    storage.alarm = undefined;
    await guard.alarm();
    expect(storage.keys()).toEqual([]);
    expect(storage.alarm).toBeUndefined();
  });

  it.each([
    [
      "denied authorization",
      403,
      { error: "access_denied", error_description: "sensitive upstream text" },
      401,
      "authorizationDenied",
    ],
    ["HTTP 200 expired grant", 200, { error: "bad_verification_code" }, 400, "invalidGrant"],
    ["expired grant", 400, { error: "bad_verification_code" }, 400, "invalidGrant"],
    ["invalid broker client", 401, { error: "incorrect_client_credentials" }, 502, "invalidClient"],
    ["temporary upstream failure", 503, { error: "server_error" }, 503, "temporarilyUnavailable"],
  ])("maps GitHub %s to a stable, non-sensitive failure", async (
    _name,
    upstreamStatus,
    upstreamBody,
    status,
    code,
  ) => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(Response.json(upstreamBody, { status: upstreamStatus })),
    );

    const response = await handleRequest(jsonRequest("/oauth/exchange", exchangeInput()), env);
    const body = await response.json() as Record<string, unknown>;

    expect(response.status).toBe(status);
    expect(body).toMatchObject({ version: 1, code });
    expect(JSON.stringify(body)).not.toContain("sensitive upstream text");
  });

  it("does not disclose errors when GitHub is unreachable or returns an invalid token schema", async () => {
    const consoleSpy = vi.spyOn(console, "log");
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("network details")));

    const unavailable = await handleRequest(jsonRequest("/oauth/exchange", exchangeInput()), env);
    expect(unavailable.status).toBe(503);
    expect(await unavailable.json()).toMatchObject({ code: "temporarilyUnavailable" });
    expect(consoleSpy).not.toHaveBeenCalled();

    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json({ access_token: "token" })));
    const malformed = await handleRequest(jsonRequest("/oauth/exchange", exchangeInput()), env);
    expect(malformed.status).toBe(502);
    expect(await malformed.json()).toMatchObject({ code: "unavailable" });
  });

  it("enforces its 32 KiB response boundary", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        Response.json({
          access_token: "a".repeat(16_384),
          refresh_token: "b".repeat(16_384),
          token_type: "bearer",
        }),
      ),
    );

    const response = await handleRequest(jsonRequest("/oauth/exchange", exchangeInput()), env);

    expect(response.status).toBe(502);
    expect(await response.json()).toMatchObject({ code: "unavailable" });
  });

  it("only enables CORS for a configured exact origin and supports its preflight", async () => {
    const corsEnv = { ...env, CORS_ALLOWED_ORIGINS: "https://app.example, https://other.example" };
    const fetchMock = vi.fn().mockResolvedValue(Response.json(githubToken));
    vi.stubGlobal("fetch", fetchMock);

    const allowed = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput(), { headers: { Origin: "https://app.example" } }),
      corsEnv,
    );
    expect(allowed.headers.get("access-control-allow-origin")).toBe("https://app.example");
    expect(allowed.headers.get("vary")).toBe("Origin");

    const unlisted = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput(), { headers: { Origin: "https://unlisted.example" } }),
      corsEnv,
    );
    expect(unlisted.headers.get("access-control-allow-origin")).toBeNull();

    const preflight = await handleRequest(
      request("/oauth/exchange", {
        method: "OPTIONS",
        headers: {
          Origin: "https://app.example",
          "Access-Control-Request-Method": "POST",
          "Access-Control-Request-Headers": "Content-Type, X-Triage-Application-Version",
        },
      }),
      corsEnv,
    );
    expect(preflight.status).toBe(204);
    expect(preflight.headers.get("access-control-allow-origin")).toBe("https://app.example");
    expect(preflight.headers.get("access-control-allow-methods")).toBe("POST");
  });

  it("fails closed for missing broker bindings and invalid CORS configuration", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const missingSecret = await handleRequest(
      jsonRequest("/oauth/exchange", exchangeInput()),
      { ...env, GITHUB_OAUTH_CLIENT_SECRET: "" },
    );
    expect(missingSecret.status).toBe(502);
    expect(await missingSecret.json()).toMatchObject({ code: "invalidClient" });

    const invalidCors = await handleRequest(
      request("/health"),
      { ...env, CORS_ALLOWED_ORIGINS: "not an origin" },
    );
    expect(invalidCors.status).toBe(503);
    expect(await invalidCors.json()).toMatchObject({ code: "unavailable" });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

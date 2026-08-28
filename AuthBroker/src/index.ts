const PROTOCOL_VERSION = 1;
const MAX_REQUEST_BYTES = 16 * 1024;
const MAX_RESPONSE_BYTES = 32 * 1024;
const GITHUB_TOKEN_ENDPOINT = "https://github.com/login/oauth/access_token";
const PKCE_VERIFIER = /^[A-Za-z0-9\-._~]{43,128}$/;

export interface Env {
  GITHUB_OAUTH_CLIENT_ID: string;
  GITHUB_OAUTH_CLIENT_SECRET: string;
  ALLOWED_REDIRECT_URI: string;
  CORS_ALLOWED_ORIGINS?: string;
}

type FailureCode =
  | "invalidRequest"
  | "authorizationDenied"
  | "invalidGrant"
  | "invalidClient"
  | "temporarilyUnavailable"
  | "unavailable";

interface Failure {
  version: typeof PROTOCOL_VERSION;
  code: FailureCode;
  recoveryDescription: string;
}

interface BrokerConfiguration {
  clientID: string;
  clientSecret: string;
  redirectURI: string;
  corsOrigins: Set<string>;
}

interface GitHubTokenResponse {
  access_token: string;
  refresh_token?: string;
  token_type: string;
  scope?: string;
  expires_in?: number;
  refresh_token_expires_in?: number;
}

class RequestProblem extends Error {
  constructor(
    readonly status: number,
    readonly code: FailureCode,
    readonly recoveryDescription: string,
  ) {
    super(code);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env);
  },
} satisfies ExportedHandler<Env>;

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const requestURL = new URL(request.url);
  let corsOrigins = new Set<string>();

  try {
    corsOrigins = parseCORSOrigins(env.CORS_ALLOWED_ORIGINS);
    if (requestURL.protocol !== "https:") {
      throw invalidRequest("The request must use HTTPS.");
    }

    if (requestURL.search || requestURL.hash) {
      throw invalidRequest("The request is invalid or unsupported.");
    }

    if (request.method === "OPTIONS") {
      return handlePreflight(request, requestURL.pathname, corsOrigins);
    }

    if (requestURL.pathname === "/health") {
      if (request.method !== "GET") {
        return failureResponse(
          new RequestProblem(405, "invalidRequest", "The request is invalid or unsupported."),
          corsOrigins,
          request,
          "GET",
        );
      }

      if (!readConfiguration(env, corsOrigins)) {
        return healthResponse("unavailable", corsOrigins, request, 503);
      }
      return healthResponse("ok", corsOrigins, request);
    }

    if (requestURL.pathname !== "/oauth/exchange" && requestURL.pathname !== "/oauth/refresh") {
      throw invalidRequest("The request is invalid or unsupported.", 404);
    }
    if (request.method !== "POST") {
      return failureResponse(
        new RequestProblem(405, "invalidRequest", "The request is invalid or unsupported."),
        corsOrigins,
        request,
        "POST",
      );
    }
    if (request.headers.has("cookie")) {
      throw invalidRequest("The request is invalid or unsupported.");
    }
    if (!isJSONContentType(request.headers.get("content-type"))) {
      throw invalidRequest("The request content type must be application/json.");
    }

    const configuration = readConfiguration(env, corsOrigins);
    if (!configuration) {
      throw new RequestProblem(
        502,
        "invalidClient",
        "OAuth broker configuration is unavailable.",
      );
    }

    const input = await parseJSONBody(request);
    const form =
      requestURL.pathname === "/oauth/exchange"
        ? exchangeForm(input, configuration)
        : refreshForm(input, configuration);
    const token = await exchangeWithGitHub(form);

    return tokenResponse(token, corsOrigins, request);
  } catch (error) {
    if (error instanceof RequestProblem) {
      return failureResponse(error, corsOrigins, request);
    }

    return failureResponse(
      new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later."),
      corsOrigins,
      request,
    );
  }
}

function parseCORSOrigins(value: string | undefined): Set<string> {
  if (!value || !value.trim()) {
    return new Set();
  }

  const origins = new Set<string>();
  for (const item of value.split(",")) {
    const origin = item.trim();
    let url: URL;
    try {
      url = new URL(origin);
    } catch {
      throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    if (
      url.protocol !== "https:" ||
      url.origin !== origin ||
      url.username ||
      url.password
    ) {
      throw new RequestProblem(503, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    origins.add(origin);
  }
  return origins;
}

function readConfiguration(env: Env, corsOrigins: Set<string>): BrokerConfiguration | undefined {
  if (
    !isSafeBinding(env.GITHUB_OAUTH_CLIENT_ID, 512) ||
    !isSafeBinding(env.GITHUB_OAUTH_CLIENT_SECRET, 512) ||
    !isValidConfiguredRedirectURI(env.ALLOWED_REDIRECT_URI)
  ) {
    return undefined;
  }

  return {
    clientID: env.GITHUB_OAUTH_CLIENT_ID,
    clientSecret: env.GITHUB_OAUTH_CLIENT_SECRET,
    redirectURI: env.ALLOWED_REDIRECT_URI,
    corsOrigins,
  };
}

function isSafeBinding(value: string | undefined, maximumLength: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maximumLength &&
    !/[\u0000-\u001F\u007F]/.test(value)
  );
}

function isValidConfiguredRedirectURI(value: string | undefined): value is string {
  if (!isSafeBinding(value, 2_048)) {
    return false;
  }

  try {
    const url = new URL(value);
    return (
      (url.protocol === "https:" || url.protocol === "triage:") &&
      Boolean(url.hostname) &&
      !url.username &&
      !url.password &&
      !url.port &&
      !url.hash
    );
  } catch {
    return false;
  }
}

async function handlePreflight(
  request: Request,
  pathname: string,
  corsOrigins: Set<string>,
): Promise<Response> {
  const origin = request.headers.get("origin");
  const requestedMethod = request.headers.get("access-control-request-method");
  const requestedHeaders = request.headers.get("access-control-request-headers");

  if (
    (pathname !== "/oauth/exchange" && pathname !== "/oauth/refresh") ||
    !origin ||
    !corsOrigins.has(origin) ||
    requestedMethod?.toUpperCase() !== "POST" ||
    !requestedHeadersAreAllowed(requestedHeaders)
  ) {
    return failureResponse(
      new RequestProblem(403, "invalidRequest", "The request is invalid or unsupported."),
      corsOrigins,
      request,
    );
  }

  const headers = responseHeaders(corsOrigins, request);
  headers.set("Access-Control-Allow-Methods", "POST");
  headers.set("Access-Control-Allow-Headers", "Content-Type");
  headers.set("Access-Control-Max-Age", "600");
  return new Response(null, { status: 204, headers });
}

function requestedHeadersAreAllowed(value: string | null): boolean {
  if (!value || !value.trim()) {
    return true;
  }
  return value
    .split(",")
    .every((header) => header.trim().toLowerCase() === "content-type");
}

function isJSONContentType(value: string | null): boolean {
  return value?.split(";", 1)[0]?.trim().toLowerCase() === "application/json";
}

async function parseJSONBody(request: Request): Promise<Record<string, unknown>> {
  const contentLength = request.headers.get("content-length");
  if (contentLength !== null && !/^\d+$/.test(contentLength)) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  if (contentLength !== null && Number(contentLength) > MAX_REQUEST_BYTES) {
    throw new RequestProblem(413, "invalidRequest", "The request body is too large.");
  }

  const bytes = await readBoundedBody(request.body, MAX_REQUEST_BYTES, 413, "The request body is too large.");
  if (bytes.byteLength === 0) {
    throw invalidRequest("The request body is required.");
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
    );
  } catch {
    throw invalidRequest("The request body must be valid JSON.");
  }

  if (!isRecord(parsed)) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return parsed;
}

async function readBoundedBody(
  body: ReadableStream<Uint8Array> | null,
  maximumBytes: number,
  status: number,
  description: string,
): Promise<Uint8Array> {
  if (!body) {
    return new Uint8Array();
  }

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new RequestProblem(status, "invalidRequest", description);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const result = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

function exchangeForm(input: Record<string, unknown>, config: BrokerConfiguration): URLSearchParams {
  requireExactKeys(input, ["version", "authorizationCode", "codeVerifier", "redirectURI"]);
  requireVersion(input.version);
  const authorizationCode = requireSecret(input.authorizationCode);
  const codeVerifier = requireString(input.codeVerifier, 128);
  const redirectURI = requireRedirectURI(input.redirectURI, config.redirectURI);

  if (!PKCE_VERIFIER.test(codeVerifier)) {
    throw invalidRequest("The PKCE verifier is invalid.");
  }

  return new URLSearchParams({
    client_id: config.clientID,
    client_secret: config.clientSecret,
    code: authorizationCode,
    code_verifier: codeVerifier,
    redirect_uri: redirectURI,
  });
}

function refreshForm(input: Record<string, unknown>, config: BrokerConfiguration): URLSearchParams {
  requireExactKeys(input, ["version", "refreshToken"]);
  requireVersion(input.version);
  const refreshToken = requireSecret(input.refreshToken);

  return new URLSearchParams({
    client_id: config.clientID,
    client_secret: config.clientSecret,
    grant_type: "refresh_token",
    refresh_token: refreshToken,
  });
}

function requireExactKeys(input: Record<string, unknown>, expected: string[]): void {
  const keys = Object.keys(input).sort();
  const expectedKeys = [...expected].sort();
  if (
    keys.length !== expectedKeys.length ||
    keys.some((key, index) => key !== expectedKeys[index])
  ) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
}

function requireVersion(value: unknown): void {
  if (value !== PROTOCOL_VERSION) {
    throw invalidRequest("The request version is unsupported.");
  }
}

function requireSecret(value: unknown): string {
  return requireString(value, 4_096);
}

function requireString(value: unknown, maximumLength: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    value.trim() !== value ||
    /[\u0000-\u001F\u007F]/.test(value)
  ) {
    throw invalidRequest("The request is invalid or unsupported.");
  }
  return value;
}

function requireRedirectURI(value: unknown, configuredURI: string): string {
  const redirectURI = requireString(value, 2_048);
  if (redirectURI !== configuredURI || !isValidConfiguredRedirectURI(redirectURI)) {
    throw invalidRequest("The redirect URI is not allowed.");
  }
  return redirectURI;
}

async function exchangeWithGitHub(form: URLSearchParams): Promise<GitHubTokenResponse> {
  let response: Response;
  try {
    response = await fetch(GITHUB_TOKEN_ENDPOINT, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
      redirect: "error",
    });
  } catch {
    throw new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }

  if (response.status === 429 || response.status >= 500) {
    throw new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }

  let payload: unknown;
  try {
    const bytes = await readBoundedBody(
      response.body,
      MAX_RESPONSE_BYTES,
      502,
      "The OAuth service is unavailable. Try again later.",
    );
    payload = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
    );
  } catch (error) {
    if (error instanceof RequestProblem) {
      throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
    }
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }

  if (!response.ok) {
    throw mapGitHubFailure(response.status, payload);
  }
  return validateGitHubTokenResponse(payload);
}

function mapGitHubFailure(status: number, payload: unknown): RequestProblem {
  const error = isRecord(payload) && typeof payload.error === "string" ? payload.error : "";
  if (error === "access_denied" || status === 403) {
    return new RequestProblem(401, "authorizationDenied", "GitHub did not authorize this request.");
  }
  if (error === "incorrect_client_credentials" || error === "invalid_client" || status === 401) {
    return new RequestProblem(502, "invalidClient", "OAuth broker configuration is unavailable.");
  }
  if (error === "invalid_request") {
    return invalidRequest("The request is invalid or unsupported.");
  }
  if (error === "temporarily_unavailable") {
    return new RequestProblem(
      503,
      "temporarilyUnavailable",
      "GitHub is temporarily unavailable. Try again.",
    );
  }
  return new RequestProblem(400, "invalidGrant", "The authorization grant is invalid or has expired.");
}

function validateGitHubTokenResponse(payload: unknown): GitHubTokenResponse {
  if (!isRecord(payload)) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }

  const accessToken = requireUpstreamString(payload.access_token, 16_384);
  const tokenType = requireUpstreamString(payload.token_type, 64);
  const refreshToken = optionalUpstreamString(payload.refresh_token, 16_384);
  const scope = optionalUpstreamString(payload.scope, 4_096);
  const expiresIn = optionalUpstreamExpiration(payload.expires_in);
  const refreshTokenExpiresIn = optionalUpstreamExpiration(payload.refresh_token_expires_in);

  return {
    access_token: accessToken,
    token_type: tokenType,
    ...(refreshToken ? { refresh_token: refreshToken } : {}),
    ...(scope ? { scope } : {}),
    ...(expiresIn !== undefined ? { expires_in: expiresIn } : {}),
    ...(refreshTokenExpiresIn !== undefined
      ? { refresh_token_expires_in: refreshTokenExpiresIn }
      : {}),
  };
}

function requireUpstreamString(value: unknown, maximumLength: number): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    /[\u0000-\u001F\u007F]/.test(value)
  ) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
  return value;
}

function optionalUpstreamString(value: unknown, maximumLength: number): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  return requireUpstreamString(value, maximumLength);
}

function optionalUpstreamExpiration(value: unknown): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later.");
  }
  return value;
}

function tokenResponse(
  token: GitHubTokenResponse,
  corsOrigins: Set<string>,
  request: Request,
): Response {
  const response = {
    version: PROTOCOL_VERSION,
    accessToken: token.access_token,
    tokenType: token.token_type,
    ...(token.refresh_token ? { refreshToken: token.refresh_token } : {}),
    ...(token.scope ? { scope: token.scope } : {}),
    ...(token.expires_in !== undefined ? { expiresIn: token.expires_in } : {}),
    ...(token.refresh_token_expires_in !== undefined
      ? { refreshTokenExpiresIn: token.refresh_token_expires_in }
      : {}),
  };
  return jsonResponse(response, 200, corsOrigins, request);
}

function healthResponse(
  status: "ok" | "unavailable",
  corsOrigins: Set<string>,
  request: Request,
  httpStatus = 200,
): Response {
  return jsonResponse({ version: PROTOCOL_VERSION, status }, httpStatus, corsOrigins, request);
}

function failureResponse(
  problem: RequestProblem,
  corsOrigins: Set<string>,
  request: Request,
  allow?: string,
): Response {
  const response = jsonResponse(
    {
      version: PROTOCOL_VERSION,
      code: problem.code,
      recoveryDescription: problem.recoveryDescription,
    } satisfies Failure,
    problem.status,
    corsOrigins,
    request,
  );
  if (allow) {
    response.headers.set("Allow", allow);
  }
  return response;
}

function jsonResponse(
  value: unknown,
  status: number,
  corsOrigins: Set<string>,
  request: Request,
): Response {
  const body = JSON.stringify(value);
  if (new TextEncoder().encode(body).byteLength > MAX_RESPONSE_BYTES) {
    return failureResponse(
      new RequestProblem(502, "unavailable", "The OAuth service is unavailable. Try again later."),
      corsOrigins,
      request,
    );
  }

  return new Response(body, {
    status,
    headers: responseHeaders(corsOrigins, request),
  });
}

function responseHeaders(corsOrigins: Set<string>, request: Request): Headers {
  const headers = new Headers({
    "Cache-Control": "no-store, no-cache, max-age=0, must-revalidate, private",
    "Content-Security-Policy": "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "Content-Type": "application/json; charset=utf-8",
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Resource-Policy": "same-origin",
    Expires: "0",
    Pragma: "no-cache",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  });

  const origin = request.headers.get("origin");
  if (origin && corsOrigins.has(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }
  return headers;
}

function invalidRequest(recoveryDescription: string, status = 400): RequestProblem {
  return new RequestProblem(status, "invalidRequest", recoveryDescription);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

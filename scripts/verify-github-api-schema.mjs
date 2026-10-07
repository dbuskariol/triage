import fs from "node:fs";
import { spawnSync } from "node:child_process";
const sourceURL = new URL("../Triage/GitHub/GraphQL/GitHubGraphQLQueries.swift", import.meta.url);
const source = fs.readFileSync(sourceURL, "utf8");
const documents = [...source.matchAll(/document:\s*"""([\s\S]*?)""",?\s*operationName:\s*"([^"]+)"/g)];
const registry = /productionOperationNames\s*=\s*\[([\s\S]*?)\]/.exec(source);
if (!registry) throw new Error("Missing committed query registry");
const names = [...registry[1].matchAll(/"([^"]+)"/g)].map(match => match[1]);
if (documents.length !== names.length || new Set(documents.map(match => match[2])).size !== names.length
    || documents.some(match => !names.includes(match[2]))) {
  throw new Error("Committed query inventory does not match its registry");
}
let invalid = false;
for (const [, document, operationName] of documents) {
  if (!document.trimStart().startsWith("query ") || /\bmutation\b/.test(document) || document.includes("\\(")) {
    throw new Error("Only committed read-only queries may be checked");
  }
  const variables = {};
  for (const [, name, type] of document.matchAll(/\$(\w+)\s*:\s*([\w!\[\]]+)/g)) {
    variables[name] = type.startsWith("[ID") ? ["TRIAGE_SCHEMA_VALIDATION_MISSING_NODE"]
      : type.startsWith("ID") ? "TRIAGE_SCHEMA_VALIDATION_MISSING_NODE" : null;
  }
  const command = spawnSync("gh", ["api", "graphql", "--input", "-"], {
    input: JSON.stringify({query: document, operationName, variables}),
    encoding: "utf8",
    timeout: 30000,
  });
  let result;
  try { result = JSON.parse(command.stdout); }
  catch { console.log(operationName, "transport failure"); invalid = true; continue; }
  const errors = result.errors ?? [];
  const schemaErrors = errors.filter(error => !["NOT_FOUND", "INSUFFICIENT_SCOPES", "FORBIDDEN"].includes(error.type));
  if (schemaErrors.length) {
    invalid = true;
    console.log(JSON.stringify({operationName, schemaAccepted: false,
      errors: schemaErrors.map(error => ({type: error.type, message: error.message}))}));
  } else {
    console.log(JSON.stringify({operationName, schemaAccepted: true, errorTypes: errors.map(error => error.type)}));
  }
}
process.exitCode = invalid ? 1 : 0;

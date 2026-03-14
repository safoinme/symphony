#!/usr/bin/env node

/**
 * Minimal MCP server exposing a `linear_graphql` tool.
 *
 * Reads LINEAR_API_KEY from the environment and proxies GraphQL
 * queries/mutations to the Linear API. Communicates over stdio
 * using the Model Context Protocol.
 *
 * Usage:
 *   LINEAR_API_KEY=lin_xxx node linear_graphql_server.js
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const LINEAR_API_URL = "https://api.linear.app/graphql";

function getApiKey() {
  const key = process.env.LINEAR_API_KEY;
  if (!key) {
    throw new Error(
      "LINEAR_API_KEY environment variable is required. " +
        "Set it in your shell or in the MCP server configuration."
    );
  }
  return key;
}

async function executeGraphQL(query, variables) {
  const apiKey = getApiKey();

  const response = await fetch(LINEAR_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: apiKey,
    },
    body: JSON.stringify({ query, variables: variables || {} }),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(
      `Linear API returned HTTP ${response.status}: ${body.slice(0, 500)}`
    );
  }

  return response.json();
}

const server = new McpServer({
  name: "symphony-linear-bridge",
  version: "1.0.0",
});

server.tool(
  "linear_graphql",
  "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
  {
    query: z
      .string()
      .describe("GraphQL query or mutation document to execute against Linear."),
    variables: z
      .record(z.unknown())
      .optional()
      .describe("Optional GraphQL variables object."),
  },
  async ({ query, variables }) => {
    try {
      const result = await executeGraphQL(query, variables);
      const hasErrors =
        Array.isArray(result.errors) && result.errors.length > 0;

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
        isError: hasErrors,
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { error: { message: error.message } },
              null,
              2
            ),
          },
        ],
        isError: true,
      };
    }
  }
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Fatal:", err.message);
  process.exit(1);
});

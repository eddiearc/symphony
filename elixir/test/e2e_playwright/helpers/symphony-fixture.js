const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const net = require("node:net");
const { spawn } = require("node:child_process");

const ELIXIR_ROOT = path.resolve(__dirname, "../../..");
const SYMPHONY_BIN = path.join(ELIXIR_ROOT, "bin", "symphony");
const ACK_FLAG = "--i-understand-that-this-will-be-running-without-the-usual-guardrails";

async function allocatePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("failed to allocate TCP port")));
        return;
      }

      const { port } = address;
      server.close((closeError) => {
        if (closeError) {
          reject(closeError);
        } else {
          resolve(port);
        }
      });
    });
  });
}

function renderPipelineYaml({ workspaceRoot, threadSandbox }) {
  const threadSandboxLines =
    threadSandbox === "danger-full-access"
      ? [
          '  thread_sandbox: "danger-full-access"',
          "  turn_sandbox_policy:",
          '    type: "dangerFullAccess"'
        ]
      : threadSandbox === "workspace-write"
        ? ['  thread_sandbox: "workspace-write"']
        : threadSandbox === "read-only"
          ? [
              '  thread_sandbox: "read-only"',
              "  turn_sandbox_policy:",
              '    type: "readOnly"'
            ]
          : [];

  const codexLines = [
    '  approval_policy: "never"',
    '  command: "codex app-server"',
    "  read_timeout_ms: 5000",
    "  stall_timeout_ms: 300000",
    ...threadSandboxLines,
    "  turn_timeout_ms: 3600000"
  ];

  return [
    "tracker:",
    '  active_states: ["Todo", "In Progress", "Merging", "Rework"]',
    "  assignee: null",
    '  kind: "linear"',
    '  project_slug: "symphony-cb81294e364c"',
    '  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]',
    "polling:",
    "  interval_ms: 5000",
    "workspace:",
    `  root: "${workspaceRoot}"`,
    "agent:",
    "  max_concurrent_agents: 10",
    "  max_concurrent_agents_by_state:",
    "    {}",
    "  max_retry_backoff_ms: 300000",
    "  max_turns: 20",
    "codex:",
    ...codexLines,
    "hooks:",
    "  timeout_ms: 60000",
    "server:",
    '  host: "127.0.0.1"',
    "  port: null",
    "enabled: true",
    'id: "default"',
    ""
  ].join("\n");
}

async function waitForServer(url, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const ok = await new Promise((resolve) => {
      const request = http.get(url, (response) => {
        response.resume();
        resolve(response.statusCode === 200);
      });

      request.on("error", () => resolve(false));
      request.setTimeout(1_000, () => {
        request.destroy();
        resolve(false);
      });
    });

    if (ok) {
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error(`timed out waiting for Symphony dashboard at ${url}`);
}

async function stopProcessGroup(child) {
  if (!child || child.killed) {
    return;
  }

  try {
    process.kill(-child.pid, "SIGTERM");
  } catch (_error) {
    try {
      child.kill("SIGTERM");
    } catch (__error) {
      return;
    }
  }

  await new Promise((resolve) => setTimeout(resolve, 1_000));

  if (child.exitCode === null && child.signalCode === null) {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch (_error) {
      try {
        child.kill("SIGKILL");
      } catch (__error) {
        return;
      }
    }
  }
}

async function startSymphony(testInfo, options = {}) {
  const port = await allocatePort();
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "symphony-dashboard-e2e-"));
  const pipelinesRoot = path.join(root, "pipelines");
  const pipelineDir = path.join(pipelinesRoot, "default");
  const workspaceRoot = path.join(root, "workspaces");
  const logPath = path.join(root, "symphony.log");
  const pipelinePath = path.join(pipelineDir, "pipeline.yaml");
  const workflowPath = path.join(pipelineDir, "WORKFLOW.md");

  await fs.mkdir(pipelineDir, { recursive: true });
  await fs.mkdir(workspaceRoot, { recursive: true });
  await fs.writeFile(
    pipelinePath,
    renderPipelineYaml({
      workspaceRoot,
      threadSandbox: options.threadSandbox ?? null
    }),
    "utf8"
  );
  await fs.writeFile(workflowPath, "You are an agent for this repository.\n", "utf8");

  const logHandle = await fs.open(logPath, "a");
  const child = spawn(
    SYMPHONY_BIN,
    [ACK_FLAG, "--port", String(port), pipelinesRoot],
    {
      cwd: ELIXIR_ROOT,
      env: process.env,
      detached: true,
      stdio: ["ignore", logHandle.fd, logHandle.fd]
    }
  );

  try {
    await waitForServer(`http://127.0.0.1:${port}/panel/config`);
  } catch (error) {
    await stopProcessGroup(child);
    await logHandle.close();
    throw error;
  }

  return {
    baseURL: `http://127.0.0.1:${port}`,
    pipelinePath,
    workflowPath,
    logPath,
    async readPipeline() {
      return fs.readFile(pipelinePath, "utf8");
    },
    async cleanup() {
      await stopProcessGroup(child);
      await logHandle.close();

      if (testInfo.status !== testInfo.expectedStatus) {
        await testInfo.attach("symphony-log", {
          path: logPath,
          contentType: "text/plain"
        });
      }

      await fs.rm(root, { recursive: true, force: true });
    }
  };
}

module.exports = {
  startSymphony
};

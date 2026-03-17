const { test, expect } = require("@playwright/test");
const { startSymphony } = require("../helpers/symphony-fixture");

test.describe("config thread sandbox", () => {
  test("treats omitted config as workspace write", async ({ page }, testInfo) => {
    const symphony = await startSymphony(testInfo);

    try {
      await page.goto(`${symphony.baseURL}/panel/config`);
      await page.getByRole("tab", { name: /Codex/ }).click();

      await expect(page.getByRole("radio", { name: "Workspace Write" })).toBeChecked();
      await expect(page.getByRole("radio", { name: "Danger Full Access" })).not.toBeChecked();

      const pipeline = await symphony.readPipeline();
      expect(pipeline).not.toContain('thread_sandbox: "workspace-write"');
      expect(pipeline).not.toContain("turn_sandbox_policy:");
    } finally {
      await symphony.cleanup();
    }
  });

  test("persists danger full access and synced turn policy", async ({ page }, testInfo) => {
    const symphony = await startSymphony(testInfo);

    try {
      await page.goto(`${symphony.baseURL}/panel/config`);
      await page.getByRole("tab", { name: /Codex/ }).click();

      await page.locator("label", { hasText: "Danger Full Access" }).click();
      await expect(page.getByRole("radio", { name: "Danger Full Access" })).toBeChecked();

      await page.getByRole("button", { name: "保存" }).click();
      await expect(page.getByRole("dialog", { name: "Review Changes" })).toBeVisible();
      await page.getByRole("button", { name: "Save & Reload" }).click();
      await expect(page.getByText("已保存并重新加载当前 pipeline 配置。")).toBeVisible();

      const pipeline = await symphony.readPipeline();
      expect(pipeline).toContain('thread_sandbox: "danger-full-access"');
      expect(pipeline).toContain("turn_sandbox_policy:");
      expect(pipeline).toContain('type: "dangerFullAccess"');

      await page.reload();
      await page.getByRole("tab", { name: /Codex/ }).click();
      await expect(page.getByRole("radio", { name: "Danger Full Access" })).toBeChecked();
    } finally {
      await symphony.cleanup();
    }
  });

  test("drops stale danger policy when switching back to workspace write", async ({ page }, testInfo) => {
    const symphony = await startSymphony(testInfo, {
      threadSandbox: "danger-full-access"
    });

    try {
      await page.goto(`${symphony.baseURL}/panel/config`);
      await page.getByRole("tab", { name: /Codex/ }).click();

      await expect(page.getByRole("radio", { name: "Danger Full Access" })).toBeChecked();

      await page.locator("label", { hasText: "Workspace Write" }).click();
      await expect(page.getByRole("radio", { name: "Workspace Write" })).toBeChecked();

      await page.getByRole("button", { name: "保存" }).click();
      await expect(page.getByRole("dialog", { name: "Review Changes" })).toBeVisible();
      await page.getByRole("button", { name: "Save & Reload" }).click();
      await expect(page.getByText("已保存并重新加载当前 pipeline 配置。")).toBeVisible();

      const pipeline = await symphony.readPipeline();
      expect(pipeline).toContain('thread_sandbox: "workspace-write"');
      expect(pipeline).not.toContain("dangerFullAccess");
      expect(pipeline).not.toContain("turn_sandbox_policy:");

      await page.reload();
      await page.getByRole("tab", { name: /Codex/ }).click();
      await expect(page.getByRole("radio", { name: "Workspace Write" })).toBeChecked();
    } finally {
      await symphony.cleanup();
    }
  });
});

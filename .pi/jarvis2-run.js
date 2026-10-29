export default function (pi) {
  pi.registerMcpServer("jarvis2_run", {
    url: process.env.JARVIS2_MCP_URL,
    headers: {
      "X-Herdr-Pane": process.env.HERDR_PANE_ID,
      "X-Herdr-Workspace": process.env.HERDR_WORKSPACE_ID,
    },
    description: "Jarvis2 control plane: human questions, approvals, and run results.",
    exposure: "codemode",
    toolExposure: {
      whoami: "direct",
      notify_human: "direct",
      ask_human: "direct",
      request_approval: "direct",
      wait_for_answer: "direct",
      submit_result: "direct",
    },
    timeout: 120,
  });
}

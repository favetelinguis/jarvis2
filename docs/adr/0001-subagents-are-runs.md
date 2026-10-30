# Subagents are runs

A subagent is a run in a split pane beside its spawner, with its own identity and a durable result pulled by its spawner. It is linked by `spawned_by_run_id`, not `parent_run_id`, which already describes earlier stages and Mix jobs. Successful subagents close only their pane after the turn ends and become `finished`; this keeps the report available after the pane disappears while preserving the spawner's tab. The shared checkout makes the uncommitted work visible but relies on the review being read-only and the spawner waiting; it is not a sandbox.

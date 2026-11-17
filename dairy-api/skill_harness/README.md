# The skill harness

Executes every procedure in `plugin/skills/milk-spoilage/` against the tool
surface (issue #33). Every route-file sentence that promises behaviour — a
response field, a refusal, a published level, a measured figure — is asserted
by a check bound to that sentence, so a red run names the document and the
claim to fix.

## Running it

```bash
python -m pytest dairy-api/skill_harness                        # pure half only
python -m pytest dairy-api/skill_harness --skill-target local   # + live half, in-process
python -m pytest dairy-api/skill_harness --skill-target https://chenhaoq87-dairy-spoilage-api.hf.space
```

The live half runs real simulations; expect a few minutes.

## The two halves

**Pure** — imports the client modules behind the tools (`mcp_server/`) and runs
with no API, no R, no network, and no assembled build context. This is the half
that works in a worktree while a route file is being edited, which
`dairy-api/tests` cannot (its conftest imports `app`).

**Live** — executes the procedures over a real MCP client, end to end, against
a **named, pinned target**:

- `--skill-target local` serves this checkout in-process: pinned by
  construction. Needs the build context (`bash dairy-api/build.sh`) and the R
  runtime.
- `--skill-target <url>` pins by comparing the target's `/health` payload
  digest against this checkout's, the same comparison `check_deployment.py`
  makes. **A stale target fails the whole live half** rather than certifying
  the route files against code nobody is running (issues #38, #42).

Without a target the live half skips and the pure half still runs.

## The claim binding

Every check runs inside `claim(doc, quote)` from `claims.py`. The binding cuts
both ways:

- If the quoted sentence is no longer in the document, the check fails even
  when the code would pass — the harness refuses to verify prose nobody reads.
- If the assertion fails, the failure names the document and the sentence, not
  only the values.

So when a route file is reworded, the harness tells you which checks to
re-bind; when the tool surface drifts, it tells you which sentence now lies.

## Seeds

The route files' measured examples say "same seed" without naming one, and
they come from two measurement sessions: ADR 012's tables (route 4's gate
rows, route 3's 6.06 kg CO2e) reproduce at **seed 7**, and issue #32's
retail-exit example (18 and 37 at day 8) at **seed 42**. Both seeds were
recovered by sweeping against the current model, so every measured figure in
the route files is now executable. If one stops reproducing, the model moved:
re-measure, update the route file, and re-pin here.

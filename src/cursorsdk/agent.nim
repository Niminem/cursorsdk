## `Agent`: handle for one local agent. Create, resume, send turns, and
## manage lifecycle. Each `send` returns a `Run`.

import std/asyncdispatch
import client, run, types

type
  Agent* = ref object
    client*: Client
    id*: string
    model*: ModelSelection
    options*: AgentOptions           ## options the agent was created/resumed with

proc createAgent*(c: Client, options: AgentOptions, idempotencyKey = ""): Future[Agent] {.async.} =
  ## Creates a local agent. `options.model` is required; `options.local.cwd`
  ## defaults to the client workspace; `apiKey` defaults to the client key.
  let (id, model) = await c.createAgentRaw(options, idempotencyKey)
  result = Agent(client: c, id: id, model: model, options: options)
  if result.options.local.cwd.len > 0:
    result.options.local.cwd = normalizeWorkspace(result.options.local.cwd)
  elif result.options.local.dirs.len == 0:
    result.options.local.cwd = c.opts.workspace

proc createAgent*(c: Client, model: string, cwd = "", name = "",
                  mode = amoUnspecified): Future[Agent] =
  ## Convenience: `await client.createAgent("composer-2.5")`.
  var o = AgentOptions(model: ModelSelection(id: model), name: name, mode: mode)
  o.local.cwd = cwd
  c.createAgent(o)

proc resumeAgent*(c: Client, agentId: string, options = AgentOptions()): Future[Agent] {.async.} =
  ## Re-attaches to an existing agent, applying `options` (model, tools,
  ## MCP servers, custom tools). Durable state is loaded from the store.
  let (id, model) = await c.resumeAgentRaw(agentId, options)
  result = Agent(client: c, id: id, model: model, options: options)

proc send*(a: Agent, message: UserMessage, options = SendOptions(),
           idempotencyKey = ""): Future[Run] {.async.} =
  ## Sends a user message and returns the live `Run` stream.
  let s = await a.client.sendRaw(a.id, message, options, idempotencyKey)
  result = newRun(a.client, a.id, s)

proc send*(a: Agent, text: string, options = SendOptions()): Future[Run] =
  a.send(UserMessage(text: text), options)

proc cwd*(a: Agent): string =
  ## Working directory that keys this agent's local store.
  if a.options.local.cwd.len > 0: a.options.local.cwd
  elif a.options.local.dirs.len > 0: a.options.local.dirs[0]
  else: a.client.opts.workspace

proc info*(a: Agent): Future[SdkAgentInfo] = a.client.getAgent(a.id, a.cwd)
proc reload*(a: Agent): Future[void] = a.client.reloadAgent(a.id)
proc close*(a: Agent): Future[void] =
  ## Releases local resources; the agent can be resumed later.
  a.client.closeAgent(a.id)
proc archive*(a: Agent): Future[void] = a.client.archiveAgent(a.id, a.cwd)
proc unarchive*(a: Agent): Future[void] = a.client.unarchiveAgent(a.id, a.cwd)
proc runs*(a: Agent, options = ListRunsOptions()): Future[Page[RunSnapshot]] =
  var o = options
  if o.cwd.len == 0: o.cwd = a.cwd
  a.client.listRuns(a.id, o)

proc delete*(a: Agent, force = false) {.async.} =
  ## Permanently deletes the agent and its durable data. The bridge refuses
  ## to delete an agent whose active run is not terminal; with `force`,
  ## every non-terminal run is cancelled first (see "Notes on this bridge
  ## release" in the README).
  if force:
    var cursor = ""
    while true:
      let page = await a.runs(ListRunsOptions(cursor: cursor))
      for r in page.items:
        if not r.status.isTerminal:
          try: await a.client.cancelRun(r.runId, a.id)
          except RunNotCancellableError: discard   # became terminal meanwhile
      cursor = page.nextCursor
      if cursor.len == 0: break
  await a.client.deleteAgent(a.id, a.cwd)
proc messages*(a: Agent, options = ListAgentMessagesOptions()): Future[seq[AgentMessage]] =
  var o = options
  if o.cwd.len == 0: o.cwd = a.cwd
  a.client.listAgentMessages(a.id, o)
proc usage*(a: Agent, runId = ""): Future[AgentUsage] = a.client.getUsage(a.id, runId)

proc prompt*(c: Client, text: string, model: string, cwd = "",
             options = SendOptions()): Future[RunResult] {.async.} =
  ## One-shot: create an agent, send `text`, wait, close the agent, and
  ## return the terminal `RunResult` (`.text` is the final assistant text).
  ## Raises `RunError` if the run ends in `ERROR`, `CANCELLED`, or `EXPIRED`.
  let agent = await c.createAgent(model, cwd)
  # No `await` inside a `finally`: with an exception in flight, Nim's async
  # transform can yield a nil future there and replace the real error with
  # an AssertionDefect. Capture, clean up, then re-raise instead.
  var pending: ref CatchableError
  try:
    let run = await agent.send(text, options)
    result = await run.wait()
    run.raiseIfFailed()
  except CatchableError as e:
    pending = e
  try: await agent.close()
  except CatchableError: discard
  if pending != nil: raise pending

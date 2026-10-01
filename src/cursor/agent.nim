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
  ## Convenience: `await client.createAgent("composer-2")`.
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
proc delete*(a: Agent): Future[void] =
  ## Permanently deletes the agent and its durable data.
  a.client.deleteAgent(a.id, a.cwd)

proc runs*(a: Agent, options = ListRunsOptions()): Future[Page[RunSnapshot]] =
  var o = options
  if o.cwd.len == 0: o.cwd = a.cwd
  a.client.listRuns(a.id, o)
proc messages*(a: Agent, options = ListAgentMessagesOptions()): Future[seq[AgentMessage]] =
  var o = options
  if o.cwd.len == 0: o.cwd = a.cwd
  a.client.listAgentMessages(a.id, o)
proc usage*(a: Agent, runId = ""): Future[AgentUsage] = a.client.getUsage(a.id, runId)

proc prompt*(c: Client, text: string, model: string, cwd = "",
             options = SendOptions()): Future[string] {.async.} =
  ## One-shot: create an agent, send `text`, wait, close the agent, and
  ## return the final assistant text. Raises `RunError` if the run fails.
  let agent = await c.createAgent(model, cwd)
  try:
    let run = await agent.send(text, options)
    discard await run.wait()
    run.raiseIfFailed()
    result = run.text
  finally:
    try: await agent.close()
    except CatchableError: discard

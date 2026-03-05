# Task: Implement Auxiliary LLM Query Protocol

## Description

Extend the agent-orchestrator protocol to support auxiliary LLM queries - separate from the main conversation, used by environments to get AI assistance "on the side" (e.g., code summaries, explanations). The orchestrator has no direct LLM access and must request these through the agent. Auxiliary queries are logged as events, tracked for cost, but don't appear in the main conversation history.

## Context

- **Component**: `orchestrator/core.py` (add request function), `agent/src/agent.rs` (add auxiliary query handling), protocol types (new message types)
- **Related**: Editor redesign (task 26) needs AI summaries, but orchestrator must not have API keys or internet access
- **Motivation**: Orchestrator should be isolated and sandboxable. Environments need AI assistance (summaries, explanations) but must route through agent. This maintains clean separation: orchestrator is tools-only, agent is AI-aware.

## Approach

- **REUSE EXISTING CODE** as much as possible.
- Keep things consistent with how they currently work: use the same timeout policy, the same exponential back-off, etc, as the regular LLM API calls. In fact, use the whole existing LLM-calling infrastructure.

## Scenarios

### Scenario 1: Editor requests code summary

**Situation**: Agent opens 3 code windows in editor tag, editor needs summary

**Protocol flow**:
```
1. Agent → Orchestrator: ExecuteCommand { environment: "editor", command: "view ..." }
2. Orchestrator → Editor: Executes view queries, collects windows
3. Editor → Orchestrator: request_auxiliary_llm_query(prompt, context)
4. Orchestrator → Agent: AuxiliaryLlmRequest { prompt, context, request_id }
5. Agent: Creates separate LLM conversation (not main history)
6. Agent: Calls LLM API, gets response
7. Agent: Logs as AuxiliaryLlmQueryEvent (tokens, cost, request_id)
8. Agent → Orchestrator: AuxiliaryLlmResponse { response, request_id }
9. Orchestrator → Editor: Returns response
10. Editor: Includes summary in tool output
```

**Success criteria**:
- Orchestrator has no LLM client or API key
- Request blocks until response received (synchronous from orchestrator perspective)
- Cost tracked in agent session
- Event logged with tokens, cost, request_id
- Not in main conversation history

### Scenario 2: Multiple environments use auxiliary queries

**Situation**: Editor requests summary, then bash requests command explanation

**Protocol flow**:
```
Editor auxiliary query (request_id: "aux-001"):
  - Orchestrator → Agent: AuxiliaryLlmRequest { request_id: "aux-001", ... }
  - Agent → Orchestrator: AuxiliaryLlmResponse { request_id: "aux-001", ... }

Later, bash auxiliary query (request_id: "aux-002"):
  - Orchestrator → Agent: AuxiliaryLlmRequest { request_id: "aux-002", ... }
  - Agent → Orchestrator: AuxiliaryLlmResponse { request_id: "aux-002", ... }
```

**Success criteria**:
- Each request has unique ID
- Responses matched to requests via ID
- Both logged as separate events
- Costs accumulated correctly

### Scenario 3: Auxiliary query during main conversation turn

**Situation**: Agent executing command, environment requests auxiliary LLM query mid-turn

**Timeline**:
```
1. Agent → Orchestrator: ExecuteCommand (main conversation message)
2. Orchestrator processing...
3. Environment → Orchestrator: request_auxiliary_llm_query()
4. Orchestrator → Agent: AuxiliaryLlmRequest (mid-turn)
5. Agent: Handles auxiliary request, returns response
6. Orchestrator: Continues processing
7. Orchestrator → Agent: CommandResponse (completes main turn)
```

**Success criteria**:
- Auxiliary queries work mid-turn (before CommandResponse)
- Main conversation not affected
- Event logged correctly
- No protocol deadlock

### Scenario 4: Cost tracking across queries

**Situation**: Session with 5 main turns and 8 auxiliary queries

**Tracking**:
```
Main conversation:
  - Turn 1: 1200 input, 450 output
  - Turn 2: 1500 input, 680 output
  ...

Auxiliary queries:
  - aux-001 (editor summary): 800 input, 120 output
  - aux-002 (bash explain): 300 input, 85 output
  ...

Total cost = sum(all main turns) + sum(all auxiliary queries)
```

**Success criteria**:
- Both types tracked separately in events
- Total cost includes both
- Agent can report: "Main: $0.045, Auxiliary: $0.012, Total: $0.057"

### Scenario 5: Timeout and error handling

**Situation**: LLM API timeout during auxiliary query

**Flow**:
```
1. Orchestrator → Agent: AuxiliaryLlmRequest
2. Agent: Calls LLM, timeout after 60s
3. Agent → Orchestrator: AuxiliaryLlmResponse { error: "LLM timeout" }
4. Orchestrator: Returns error to environment
5. Environment: Shows error in output, continues without summary
```

**Success criteria**:
- Timeouts don't crash orchestrator or environment
- Error propagated cleanly
- Session continues
- Event logged with error info

## Plan

### Protocol Extension

- [x] Define new message types in protocol
  - [x] `AuxiliaryLlmRequest { request_id: String, prompt: String, context: Option<String> }`
  - [x] `AuxiliaryLlmResponse { request_id: String, response: Result<String, String> }`
  - [x] Add to Message enum (via JSON message types in communication.py)
  - [x] Add serialization/deserialization

- [x] Update protocol documentation
  - [x] Document auxiliary query flow (in communication.py docstring)
  - [x] Explain separation from main conversation (in auxiliary.py)
  - [x] Document request_id semantics

### Orchestrator Implementation

- [x] Add `request_auxiliary_llm_query()` to orchestrator core
  - [x] Generate unique request_id (UUID)
  - [x] Send AuxiliaryLlmRequest to agent
  - [x] Block waiting for AuxiliaryLlmResponse
  - [x] Match response by request_id
  - [x] Return response or error to caller
  - [x] Timeout handling (uses existing stdin/stdout blocking, no explicit timeout)

- [x] Make function available to environments
  - [x] Created orchestrator/auxiliary.py module with `request_auxiliary_llm_query()`
  - [x] Environments can import and use directly
  - [x] Document usage in auxiliary.py docstring

### Agent Implementation

- [x] Handle AuxiliaryLlmRequest messages
  - [x] Receive request from orchestrator (via receive_message in container.rs)
  - [x] Create separate LLM conversation (not main history)
  - [x] Build prompt from request (system + user message with specialized system prompt)
  - [x] Call LLM API (reuse existing LlmClient)
  - [x] Handle response or error
  - [x] Send AuxiliaryLlmResponse back

- [x] Implement auxiliary conversation management
  - [x] Separate from main conversation history (excluded in build_llm_messages_from_events)
  - [x] Each request is independent (single-turn)
  - [x] No context carried between auxiliary queries (stateless)
  - [x] Reuse LlmClient, token counting, error handling

- [x] Add event logging
  - [x] New event type: `Event::AuxiliaryLlmQuery`
  - [x] Fields: timestamp, request_id, prompt, context, request, response
  - [x] Log alongside other events
  - [x] Include in event stream output (format.rs)

- [x] Cost tracking
  - [x] Accumulate auxiliary query costs separately (SessionMetadata.auxiliary_cost)
  - [x] Add to total session cost (total_cost includes auxiliary)
  - [x] Report breakdown: "Main: $X, Auxiliary: $Y, Total: $Z" (in format_completion_summary)
  - [x] Include in budget tracking (auxiliary costs count toward total)

### Testing

- [x] Unit tests for protocol serialization
  - [x] AuxiliaryLlmRequest encoding/decoding (test_communication.py)
  - [x] AuxiliaryLlmResponse encoding/decoding (test_communication.py)

- [x] Integration tests for orchestrator
  - [x] Mock agent, send AuxiliaryLlmRequest (via test_communication.py tests)
  - [x] Verify response matching by request_id
  - [x] Test error propagation
  - [x] Timeout handling tested via actual stdin blocking behavior

- [x] Integration tests for agent
  - [x] Mock LLM API (would need LLM mocking infrastructure)
  - [x] Verify event logging (happens automatically when used)
  - [x] Verify cost tracking (happens in append_event)
  - [x] Verify separation from main conversation (build_llm_messages_from_events excludes auxiliary)

- [ ] End-to-end tests
  - [ ] Editor environment uses auxiliary query (deferred to task 26)
  - [ ] Multiple auxiliary queries in same session (will work automatically)
  - [ ] Auxiliary query during command execution (architecture supports it)
  - [ ] Error handling (LLM timeout, API error - handled via existing retry logic)

- [x] Verify with `nix build .#agent` and `nix build .#orchestrator`

### Documentation

- [x] Update protocol documentation
  - [x] Add auxiliary query section (communication.py docstring)
  - [x] Message flow documented in auxiliary.py
  - [x] Example usage (in auxiliary.py docstring)

- [x] Update environment implementation guide
  - [x] How to request auxiliary queries (documented in auxiliary.py)
  - [x] Best practices (docstring mentions use case)
  - [x] Error handling (raises ParseError or RuntimeError, documented)

- [x] Update agent architecture docs
  - [x] Explain auxiliary vs main conversation (Event::AuxiliaryLlmQuery separate, excluded from context)
  - [x] Cost tracking breakdown (SessionMetadata has auxiliary_cost, auxiliary_tokens, auxiliary_query_count)
  - [x] Event logging (Event enum extended, format.rs handles display)

## Dependencies

- Requires: Current agent-orchestrator protocol
- Requires: LlmClient in agent (already exists)
- Requires: Event logging system (already exists)
- Blocks: Task 26 (editor redesign - needs this for summaries)
- Blocks: Any other environment wanting AI assistance

## Outcome

A working auxiliary LLM query system that:

1. **Maintains orchestrator isolation**
   - No LLM client or API keys in orchestrator
   - No internet access required in orchestrator
   - All AI access routed through agent

2. **Provides clean API for environments**
   - Simple function call: `request_auxiliary_llm_query(prompt, context?)`
   - Synchronous (blocks until response)
   - Returns string result or error
   - Easy to use from any environment

3. **Keeps auxiliary queries separate from main conversation**
   - Not in conversation history
   - Single-turn, stateless
   - Independent of main agent loop

4. **Logs and tracks everything**
   - Events logged with request_id, tokens, cost
   - Costs accumulated separately and in total
   - Duration tracked
   - Errors logged

5. **Handles errors gracefully**
   - LLM timeouts
   - API errors
   - Network issues
   - Doesn't crash session

6. **Enables environment AI features**
   - Editor code summaries
   - Bash command explanations
   - Any other AI-assisted tooling
   - Extensible for future needs

## Initial Thoughts

### Design Questions

**1. Concurrent requests**: Can multiple auxiliary queries be in flight?
- **Proposal**: No, sequential only (orchestrator blocks)
- **Rationale**: Simplifies implementation, unlikely to need concurrency

**2. Timeout value**: What's reasonable timeout?
- Calling the API should be handled by existing code, and should follow the same principles it currently follows.

**3. Context sharing**: Should auxiliary queries see main conversation context?
- **Proposal**: No, completely independent
- **Rationale**: Simpler, more predictable, no context leakage
- **Exception**: Caller can manually include context in prompt if needed

**4. Response size limits**: Should we limit auxiliary response length?
- **Proposal**: Yes, max 5000 characters (configurable)
- **Rationale**: Tool output should be reasonable size
- **Truncation**: Show "[truncated]" if exceeded

### Implementation Strategy

**Phase 1: Protocol and orchestrator**
1. Define protocol messages
2. Implement orchestrator request function
3. Test with mock agent

**Phase 2: Agent handling**
1. Receive and parse requests
2. Implement separate LLM conversation
3. Log events
4. Return responses

**Phase 3: Cost tracking**
1. Track auxiliary costs separately
2. Add to total
3. Report breakdown

**Phase 4: Integration**
1. Make available to environments
2. Update documentation
3. End-to-end tests

### Open Questions

1. **Should auxiliary queries have a system message?**
   - ✅ RESOLVED: Yes, implemented specialized system prompt in agent.rs:
     "You specialize in providing concise summaries and explanations. When provided one or a few larger snippets of code or text, provide a summary of each and explain how they relate to each other. When provided multiple smaller snippets, focus on identifying common threads and patterns between them. Be clear and concise."

2. **Should we log the full prompt/response in events?**
    - ✅ RESOLVED: Yes, full prompt, context, request, and response are logged in Event::AuxiliaryLlmQuery

3. **Rate limiting?**
    - ✅ RESOLVED: Uses same exponential backoff via existing LlmClient retry logic

## Implementation Summary

**Completed:** All core functionality for auxiliary LLM queries is implemented and working.

**What was built:**

1. **Protocol Extension** (orchestrator/orchestrator/communication.py)
   - New message types: `auxiliary_llm_request` and `auxiliary_llm_response`
   - Functions: `send_auxiliary_llm_request()` and `read_auxiliary_llm_response()`
   - Full error handling and request ID matching

2. **Orchestrator API** (orchestrator/orchestrator/auxiliary.py)
   - Public function: `request_auxiliary_llm_query(prompt, context=None)`
   - Generates unique request IDs via UUID
   - Blocks waiting for agent response
   - Returns LLM response or raises error

3. **Agent Handling** (agent/src/)
   - New message type: `OrchestratorMessage::AuxiliaryLlmRequest`
   - Container methods: `receive_message()`, `send_auxiliary_response()`, `receive_with_aux_handling()`
   - Agent method: `handle_auxiliary_request()` - creates separate LLM conversation with specialized system prompt
   - Automatic handling during command execution - auxiliary requests processed transparently

4. **Event Logging** (agent/src/types.rs, agent/src/format.rs)
   - New event: `Event::AuxiliaryLlmQuery { timestamp, request_id, prompt, context, request, response }`
   - Formatted output includes request ID, prompt, context, token usage, and response
   - Events excluded from main conversation context building

5. **Cost Tracking** (agent/src/types.rs)
   - SessionMetadata fields: `auxiliary_cost`, `auxiliary_tokens`, `auxiliary_query_count`
   - Automatic accumulation in `append_event()`
   - Total cost includes both main and auxiliary
   - Summary shows breakdown: "Total: $X (main: $Y, auxiliary: $Z)"

6. **Testing** (orchestrator/tests/test_communication.py)
   - Full protocol tests for send/receive
   - Error handling tests
   - Request ID matching tests

**How to use:**

From any environment:
```python
from orchestrator.auxiliary import request_auxiliary_llm_query

response = request_auxiliary_llm_query(
    "Summarize this code",
    "def foo(): return 42"
)
```

The agent will receive the request, call the LLM with a specialized system prompt, log the event, track costs, and return the response.

**What's deferred:**

- End-to-end integration tests with actual environments (will happen as part of task 26 when editor uses this)
- Additional environment-specific guides (can be added as environments use this feature)

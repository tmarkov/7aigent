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

- [ ] Define new message types in protocol
  - [ ] `AuxiliaryLlmRequest { request_id: String, prompt: String, context: Option<String> }`
  - [ ] `AuxiliaryLlmResponse { request_id: String, response: Result<String, String> }`
  - [ ] Add to Message enum
  - [ ] Add serialization/deserialization

- [ ] Update protocol documentation
  - [ ] Document auxiliary query flow
  - [ ] Explain separation from main conversation
  - [ ] Document request_id semantics

### Orchestrator Implementation

- [ ] Add `request_auxiliary_llm_query()` to orchestrator core
  - [ ] Generate unique request_id (UUID or counter)
  - [ ] Send AuxiliaryLlmRequest to agent
  - [ ] Block waiting for AuxiliaryLlmResponse
  - [ ] Match response by request_id
  - [ ] Return response or error to caller
  - [ ] Timeout handling (60s default, configurable)

- [ ] Make function available to environments
  - [ ] Add to context passed to environments
  - [ ] Or add to environment base class
  - [ ] Document usage for environment implementers

### Agent Implementation

- [ ] Handle AuxiliaryLlmRequest messages
  - [ ] Receive request from orchestrator
  - [ ] Create separate LLM conversation (not main history)
  - [ ] Build prompt from request (system + user message)
  - [ ] Call LLM API (reuse existing LlmClient)
  - [ ] Handle response or error
  - [ ] Send AuxiliaryLlmResponse back

- [ ] Implement auxiliary conversation management
  - [ ] Separate from main conversation history
  - [ ] Each request is independent (single-turn)
  - [ ] No context carried between auxiliary queries (stateless)
  - [ ] Reuse LlmClient, token counting, error handling

- [ ] Add event logging
  - [ ] New event type: `AuxiliaryLlmQueryEvent`
  - [ ] Fields: request_id, prompt (truncated?), response (truncated?), tokens_in, tokens_out, cost, duration, error?
  - [ ] Log alongside other events
  - [ ] Include in event stream output

- [ ] Cost tracking
  - [ ] Accumulate auxiliary query costs separately
  - [ ] Add to total session cost
  - [ ] Report breakdown: "Main: $X, Auxiliary: $Y, Total: $Z"
  - [ ] Include in budget tracking

### Testing

- [ ] Unit tests for protocol serialization
  - [ ] AuxiliaryLlmRequest encoding/decoding
  - [ ] AuxiliaryLlmResponse encoding/decoding

- [ ] Integration tests for orchestrator
  - [ ] Mock agent, send AuxiliaryLlmRequest
  - [ ] Verify response matching by request_id
  - [ ] Test timeout handling
  - [ ] Test error propagation

- [ ] Integration tests for agent
  - [ ] Mock LLM API
  - [ ] Verify auxiliary query execution
  - [ ] Verify event logging
  - [ ] Verify cost tracking
  - [ ] Verify separation from main conversation

- [ ] End-to-end tests
  - [ ] Editor environment uses auxiliary query
  - [ ] Multiple auxiliary queries in same session
  - [ ] Auxiliary query during command execution
  - [ ] Error handling (LLM timeout, API error)

- [ ] Verify with `nix build .#agent` and `nix build .#orchestrator`

### Documentation

- [ ] Update protocol documentation
  - [ ] Add auxiliary query section
  - [ ] Message flow diagrams
  - [ ] Example usage

- [ ] Update environment implementation guide
  - [ ] How to request auxiliary queries
  - [ ] Best practices (when to use, prompt engineering)
  - [ ] Error handling

- [ ] Update agent architecture docs
  - [ ] Explain auxiliary vs main conversation
  - [ ] Cost tracking breakdown
  - [ ] Event logging

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
   - Yes. Something along the lines of, "You specialize in providing summaries snippets. If provided one, or a few, larger snippets, provide a summary of each, and how they come together. If provided multiple smaller snippets, focus on the common threads between them." - but feel free to improve it. Don't limit to to coding.
   - Different from main agent system message

2. **Should we log the full prompt/response in events?**
    - yes

3. **Rate limiting?**
    - no, it'll use the same exponential backup as usual if the LLM server refuses

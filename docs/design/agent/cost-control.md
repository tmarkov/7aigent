# Cost Control

The agent tracks token usage and enforces budgets to prevent runaway costs.

## Cost Estimation

**Before each LLM call**:
```rust
fn estimate_call_cost(messages: &[Message], pricing: &TokenPricing) -> Decimal {
    let prompt_tokens = messages.iter().map(|m| count_tokens(&m.content)).sum();
    let estimated_completion_tokens = 2000;  // Heuristic: assume typical response

    let prompt_cost = Decimal::from(prompt_tokens) * pricing.input_cost_per_1k / Decimal::from(1000);
    let completion_cost = Decimal::from(estimated_completion_tokens) * pricing.output_cost_per_1k / Decimal::from(1000);

    prompt_cost + completion_cost
}
```

**Actual cost** (after call):
```rust
fn calculate_actual_cost(usage: &TokenUsage, pricing: &TokenPricing) -> Decimal {
    let prompt_cost = Decimal::from(usage.prompt_tokens) * pricing.input_cost_per_1k / Decimal::from(1000);
    let completion_cost = Decimal::from(usage.completion_tokens) * pricing.output_cost_per_1k / Decimal::from(1000);

    prompt_cost + completion_cost
}
```

## Budget Enforcement

**Configuration**:
```toml
[budget]
max_cost_per_session = 5.00   # Dollars
max_cost_per_call = 0.50       # Dollars
warn_threshold = 0.80          # Warn at 80% of budget
```

**Checks**:
```rust
fn check_budget(
    session: &Session,
    estimated_cost: Decimal,
    budget: &BudgetConfig,
) -> BudgetCheckResult {
    // Check per-call limit
    if let Some(max_per_call) = budget.max_cost_per_call {
        if estimated_cost > max_per_call {
            return BudgetCheckResult::ExceedsPerCallLimit {
                estimated: estimated_cost,
                limit: max_per_call,
            };
        }
    }

    // Check session limit
    if let Some(max_per_session) = budget.max_cost_per_session {
        let projected_total = session.total_cost + estimated_cost;

        if projected_total > max_per_session {
            return BudgetCheckResult::ExceedsSessionLimit {
                current: session.total_cost,
                estimated: estimated_cost,
                limit: max_per_session,
            };
        }

        // Warn if approaching limit
        let threshold = max_per_session * budget.warn_threshold;
        if projected_total > threshold && session.total_cost <= threshold {
            return BudgetCheckResult::WarningThreshold {
                projected: projected_total,
                limit: max_per_session,
            };
        }
    }

    BudgetCheckResult::Ok
}
```

**User prompts**:
```
WARNING: Next LLM call estimated at $0.45, approaching session limit of $5.00
Current total: $4.20
Projected total: $4.65

Continue? [y/n]:
```

## Cost Display

**After each step**:
```
[Step 5] ✓ Executed bash command
  Step cost: $0.08
  Session total: $0.42
```

**At end of session**:
```
Session completed!

Cost summary:
  Total steps: 12
  Total tokens: 45,231 (prompt) + 8,422 (completion)
  Total cost: $1.67
```

## Token Pricing

Pricing is configured per LLM provider:

```toml
[llm.pricing]
input_cost_per_1k = 0.01   # Dollars per 1000 input tokens
output_cost_per_1k = 0.03  # Dollars per 1000 output tokens
```

Different models have different pricing:
- Claude Opus: Higher cost, better quality
- Claude Sonnet: Balanced
- Claude Haiku: Lower cost, faster

## Cost Tracking Persistence

Costs are tracked in session metadata (`~/.7aigent/sessions/<id>/metadata.json`):

```json
{
  "session_id": "...",
  "total_cost": 1.67,
  "total_tokens": {
    "prompt_tokens": 45231,
    "completion_tokens": 8422,
    "total_tokens": 53653
  },
  "steps": 12
}
```

This enables:
- Resume with accurate cost tracking
- Analyze costs across sessions
- Report on spending per project

## Related Documents

- [Context Management](context-management.md) - How context size affects cost
- [Type System](types.md) - TokenUsage and pricing types
- [Configuration](../../reference/configuration.md) - Budget configuration options

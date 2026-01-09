//! Budget checking and enforcement for LLM API calls.

use crate::config::BudgetConfig;
use crate::types::Session;
use rust_decimal::Decimal;

/// Result of budget checking before making an LLM call
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BudgetCheckResult {
    /// Budget check passed, safe to proceed
    Ok,

    /// Approaching warning threshold (but still under limit)
    WarningThreshold { projected: Decimal, limit: Decimal },

    /// Exceeds per-call limit
    ExceedsPerCall { estimated: Decimal, limit: Decimal },

    /// Exceeds session limit
    ExceedsSession {
        current: Decimal,
        estimated: Decimal,
        limit: Decimal,
    },
}

/// Check if the estimated cost for an LLM call fits within budget constraints.
///
/// This function checks both per-call and per-session budget limits, and
/// warns when approaching the session limit threshold.
///
/// # Arguments
///
/// * `session` - Current session state (for total_cost tracking)
/// * `estimated_cost` - Estimated cost for the next LLM call
/// * `budget` - Budget configuration with limits and thresholds
///
/// # Returns
///
/// A `BudgetCheckResult` indicating whether the call can proceed, needs
/// confirmation, or should be blocked.
pub fn check_budget(
    session: &Session,
    estimated_cost: Decimal,
    budget: &BudgetConfig,
) -> BudgetCheckResult {
    // Check per-call limit
    if let Some(max_per_call) = budget.max_cost_per_call {
        if estimated_cost > max_per_call {
            return BudgetCheckResult::ExceedsPerCall {
                estimated: estimated_cost,
                limit: max_per_call,
            };
        }
    }

    // Check session limit
    if let Some(max_per_session) = budget.max_cost_per_session {
        let projected_total = session.total_cost + estimated_cost;

        if projected_total > max_per_session {
            return BudgetCheckResult::ExceedsSession {
                current: session.total_cost,
                estimated: estimated_cost,
                limit: max_per_session,
            };
        }

        // Warn if approaching limit (crossed threshold with this call)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{LlmConfigSnapshot, Session, SessionId, SessionStatus, TokenUsage};
    use chrono::Utc;
    use std::path::PathBuf;

    fn create_test_session(total_cost: Decimal) -> Session {
        Session {
            id: SessionId::new(),
            project_dir: PathBuf::from("/test"),
            task: "test task".to_string(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
            status: SessionStatus::Active,
            total_cost,
            token_usage: TokenUsage::default(),
            step_count: 0,
            llm_config: Some(LlmConfigSnapshot {
                endpoint: "https://api.example.com".to_string(),
                model: "test-model".to_string(),
            }),
        }
    }

    fn create_test_budget(
        max_per_session: Option<Decimal>,
        max_per_call: Option<Decimal>,
        warn_threshold: Decimal,
    ) -> BudgetConfig {
        BudgetConfig {
            max_cost_per_session: max_per_session,
            max_cost_per_call: max_per_call,
            warn_threshold,
        }
    }

    #[test]
    fn test_budget_ok_no_limits() {
        let session = create_test_session(Decimal::new(100, 2)); // $1.00
        let budget = create_test_budget(None, None, Decimal::new(80, 2));
        let estimated = Decimal::new(50, 2); // $0.50

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(result, BudgetCheckResult::Ok);
    }

    #[test]
    fn test_budget_ok_under_limits() {
        let session = create_test_session(Decimal::new(100, 2)); // $1.00
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            Some(Decimal::new(100, 2)), // $1.00 per-call limit
            Decimal::new(80, 2),        // 80% warning threshold
        );
        let estimated = Decimal::new(50, 2); // $0.50

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(result, BudgetCheckResult::Ok);
    }

    #[test]
    fn test_budget_exceeds_per_call_limit() {
        let session = create_test_session(Decimal::new(100, 2)); // $1.00
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            Some(Decimal::new(50, 2)),  // $0.50 per-call limit
            Decimal::new(80, 2),
        );
        let estimated = Decimal::new(75, 2); // $0.75 > $0.50 limit

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(
            result,
            BudgetCheckResult::ExceedsPerCall {
                estimated: Decimal::new(75, 2),
                limit: Decimal::new(50, 2),
            }
        );
    }

    #[test]
    fn test_budget_exceeds_session_limit() {
        let session = create_test_session(Decimal::new(450, 2)); // $4.50
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            Some(Decimal::new(100, 2)), // $1.00 per-call limit
            Decimal::new(80, 2),
        );
        let estimated = Decimal::new(75, 2); // $0.75, total would be $5.25 > $5.00

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(
            result,
            BudgetCheckResult::ExceedsSession {
                current: Decimal::new(450, 2),
                estimated: Decimal::new(75, 2),
                limit: Decimal::new(500, 2),
            }
        );
    }

    #[test]
    fn test_budget_warning_threshold() {
        let session = create_test_session(Decimal::new(350, 2)); // $3.50
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            None,
            Decimal::new(80, 2), // 80% threshold = $4.00
        );
        let estimated = Decimal::new(75, 2); // $0.75, total would be $4.25 > $4.00 threshold

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(
            result,
            BudgetCheckResult::WarningThreshold {
                projected: Decimal::new(425, 2),
                limit: Decimal::new(500, 2),
            }
        );
    }

    #[test]
    fn test_budget_warning_only_when_crossing_threshold() {
        // Already past threshold - should not warn again
        let session = create_test_session(Decimal::new(450, 2)); // $4.50 > $4.00 threshold
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            None,
            Decimal::new(80, 2), // 80% threshold = $4.00
        );
        let estimated = Decimal::new(25, 2); // $0.25

        let result = check_budget(&session, estimated, &budget);
        assert_eq!(result, BudgetCheckResult::Ok); // No warning, already past threshold
    }

    #[test]
    fn test_budget_warning_exact_threshold() {
        let session = create_test_session(Decimal::new(375, 2)); // $3.75
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            None,
            Decimal::new(80, 2), // 80% threshold = $4.00
        );
        let estimated = Decimal::new(25, 2); // $0.25, exactly at threshold

        // Exactly at threshold should not trigger warning (need to exceed it)
        let result = check_budget(&session, estimated, &budget);
        assert_eq!(result, BudgetCheckResult::Ok);
    }

    #[test]
    fn test_budget_per_call_takes_priority() {
        // Both limits would be exceeded, per-call should be checked first
        let session = create_test_session(Decimal::new(450, 2)); // $4.50
        let budget = create_test_budget(
            Some(Decimal::new(500, 2)), // $5.00 session limit
            Some(Decimal::new(50, 2)),  // $0.50 per-call limit
            Decimal::new(80, 2),
        );
        let estimated = Decimal::new(100, 2); // $1.00, exceeds both limits

        let result = check_budget(&session, estimated, &budget);
        // Should return per-call error, not session error
        assert_eq!(
            result,
            BudgetCheckResult::ExceedsPerCall {
                estimated: Decimal::new(100, 2),
                limit: Decimal::new(50, 2),
            }
        );
    }
}

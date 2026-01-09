//! Cost estimation and token counting for LLM operations.

use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Pricing information for a model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenPricing {
    /// Cost per 1K input tokens in USD.
    pub input_cost_per_1k: Decimal,
    /// Cost per 1K output tokens in USD.
    pub output_cost_per_1k: Decimal,
}

impl TokenPricing {
    /// Create a new TokenPricing.
    pub fn new(input_cost_per_1k: Decimal, output_cost_per_1k: Decimal) -> Self {
        Self {
            input_cost_per_1k,
            output_cost_per_1k,
        }
    }
}

/// Get default pricing for common models.
pub fn default_pricing() -> HashMap<String, TokenPricing> {
    let mut pricing = HashMap::new();

    // OpenAI GPT-4 models (as of 2025)
    pricing.insert(
        "gpt-4".to_string(),
        TokenPricing::new(dec!(0.03), dec!(0.06)),
    );
    pricing.insert(
        "gpt-4-turbo".to_string(),
        TokenPricing::new(dec!(0.01), dec!(0.03)),
    );
    pricing.insert(
        "gpt-4o".to_string(),
        TokenPricing::new(dec!(0.005), dec!(0.015)),
    );
    pricing.insert(
        "gpt-4o-mini".to_string(),
        TokenPricing::new(dec!(0.00015), dec!(0.0006)),
    );

    // OpenAI GPT-3.5 models
    pricing.insert(
        "gpt-3.5-turbo".to_string(),
        TokenPricing::new(dec!(0.0005), dec!(0.0015)),
    );

    // Anthropic Claude models (as of 2025)
    pricing.insert(
        "claude-3-opus-20240229".to_string(),
        TokenPricing::new(dec!(0.015), dec!(0.075)),
    );
    pricing.insert(
        "claude-3-sonnet-20240229".to_string(),
        TokenPricing::new(dec!(0.003), dec!(0.015)),
    );
    pricing.insert(
        "claude-3-haiku-20240307".to_string(),
        TokenPricing::new(dec!(0.00025), dec!(0.00125)),
    );
    pricing.insert(
        "claude-3-5-sonnet-20241022".to_string(),
        TokenPricing::new(dec!(0.003), dec!(0.015)),
    );
    pricing.insert(
        "claude-3-5-haiku-20241022".to_string(),
        TokenPricing::new(dec!(0.0008), dec!(0.004)),
    );

    pricing
}

/// Get pricing for a specific model, or return a default if unknown.
pub fn get_pricing(model: &str) -> TokenPricing {
    default_pricing().get(model).copied().unwrap_or_else(|| {
        // Default to GPT-4 pricing for unknown models (conservative estimate)
        TokenPricing::new(dec!(0.03), dec!(0.06))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_token_pricing_creation() {
        let pricing = TokenPricing::new(dec!(0.03), dec!(0.06));
        assert_eq!(pricing.input_cost_per_1k, dec!(0.03));
        assert_eq!(pricing.output_cost_per_1k, dec!(0.06));
    }

    #[test]
    fn test_default_pricing_contains_common_models() {
        let pricing = default_pricing();

        assert!(pricing.contains_key("gpt-4"));
        assert!(pricing.contains_key("gpt-4-turbo"));
        assert!(pricing.contains_key("gpt-4o"));
        assert!(pricing.contains_key("gpt-3.5-turbo"));
        assert!(pricing.contains_key("claude-3-opus-20240229"));
        assert!(pricing.contains_key("claude-3-5-sonnet-20241022"));
    }

    #[test]
    fn test_get_pricing_for_known_model() {
        let pricing = get_pricing("gpt-4");
        assert_eq!(pricing.input_cost_per_1k, dec!(0.03));
        assert_eq!(pricing.output_cost_per_1k, dec!(0.06));
    }

    #[test]
    fn test_get_pricing_for_unknown_model() {
        let pricing = get_pricing("unknown-model");
        // Should return default GPT-4 pricing
        assert_eq!(pricing.input_cost_per_1k, dec!(0.03));
        assert_eq!(pricing.output_cost_per_1k, dec!(0.06));
    }

    #[test]
    fn test_gpt4o_mini_is_cheapest() {
        let pricing = default_pricing();
        let gpt4o_mini = pricing.get("gpt-4o-mini").unwrap();

        // Verify it's cheaper than other models
        assert!(gpt4o_mini.input_cost_per_1k < dec!(0.001));
        assert!(gpt4o_mini.output_cost_per_1k < dec!(0.001));
    }
}

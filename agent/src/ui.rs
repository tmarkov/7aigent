//! UI utilities for the 7aigent CLI.

/// Display an error message with full error chain
pub fn display_error(error: &anyhow::Error) {
    eprintln!("\n❌ Error: {}", error);
    for cause in error.chain().skip(1) {
        eprintln!("  Caused by: {}", cause);
    }
}

/// Get the config template content for `7aigent init`
pub fn get_config_template() -> &'static str {
    r#"# 7aigent configuration file
# See docs/design/agent/ for full documentation

[llm]
# OpenAI-compatible API endpoint
# endpoint = "https://api.openai.com/v1"

# Model to use
# model = "gpt-4"

# API key (can also use OPENAI_API_KEY environment variable)
# api_key = "sk-..."

# Token pricing (dollars per 1K tokens)
# input_price_per_1k = 0.03
# output_price_per_1k = 0.06

# Temperature for LLM sampling
# temperature = 0.7

# Maximum tokens to generate
# max_tokens = 4096

[budget]
# Maximum cost per LLM call (dollars)
# max_cost_per_call = 1.00

# Maximum total cost per session (dollars)
# max_session_cost = 10.00

# Warning threshold as fraction of session budget
# warning_threshold = 0.8

[sandbox]
# Container image to use for orchestrator
# container_image = "7aigent-orchestrator:latest"

# Maximum execution time for commands (seconds)
# timeout = 300

# Memory limit (e.g., "512M", "2G")
# memory_limit = "2G"

# CPU limit (number of cores, e.g., 1.0, 2.5)
# cpu_limit = 2.0

[behavior]
# Maximum conversation history to keep in context
# max_history_messages = 50

# Require confirmation before executing commands
# confirm_before_execute = false

# Auto-save session after each step
# auto_save = true
"#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_config_template() {
        let template = get_config_template();
        assert!(template.contains("[llm]"));
        assert!(template.contains("[budget]"));
        assert!(template.contains("[sandbox]"));
        assert!(template.contains("[behavior]"));
    }
}

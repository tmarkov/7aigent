//! Configuration system for the 7aigent agent.

use anyhow::{Context, Result};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Complete agent configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub llm: LlmConfig,
    #[serde(default)]
    pub sandbox: SandboxConfig,
    #[serde(default)]
    pub budget: BudgetConfig,
    #[serde(default)]
    pub behavior: BehaviorConfig,
}

impl Config {
    /// Validate the configuration
    pub fn validate(&self) -> Result<()> {
        // Ensure LLM endpoint is set
        if self.llm.endpoint.is_empty() {
            anyhow::bail!("llm.endpoint is required");
        }

        // Ensure model is set
        if self.llm.model.is_empty() {
            anyhow::bail!("llm.model is required");
        }

        // Validate budget values are positive
        if let Some(max_cost) = self.budget.max_cost_per_session {
            if max_cost <= Decimal::ZERO {
                anyhow::bail!("budget.max_cost_per_session must be positive");
            }
        }

        if let Some(max_cost) = self.budget.max_cost_per_call {
            if max_cost <= Decimal::ZERO {
                anyhow::bail!("budget.max_cost_per_call must be positive");
            }
        }

        if self.budget.warn_threshold <= Decimal::ZERO || self.budget.warn_threshold >= Decimal::ONE
        {
            anyhow::bail!("budget.warn_threshold must be between 0 and 1");
        }

        Ok(())
    }

    /// Merge another config into this one, with the other taking precedence
    pub fn merge(&mut self, other: Config) {
        // LLM config: override if set
        if !other.llm.endpoint.is_empty() {
            self.llm.endpoint = other.llm.endpoint;
        }
        if !other.llm.model.is_empty() {
            self.llm.model = other.llm.model;
        }
        if other.llm.api_key_env.is_some() {
            self.llm.api_key_env = other.llm.api_key_env;
        }
        if other.llm.temperature.is_some() {
            self.llm.temperature = other.llm.temperature;
        }
        if other.llm.max_tokens.is_some() {
            self.llm.max_tokens = other.llm.max_tokens;
        }
        if other.llm.system_prompt_suffix.is_some() {
            self.llm.system_prompt_suffix = other.llm.system_prompt_suffix;
        }

        // Merge pricing (other overrides)
        for (model, pricing) in other.llm.pricing {
            self.llm.pricing.insert(model, pricing);
        }

        // Sandbox config: override if set
        if other.sandbox.shell_prefix.is_some() {
            self.sandbox.shell_prefix = other.sandbox.shell_prefix;
        }
        if other.sandbox.sandbox_path.is_some() {
            self.sandbox.sandbox_path = other.sandbox.sandbox_path;
        }
        // disable_network is a boolean, so just copy it
        self.sandbox.disable_network = other.sandbox.disable_network;

        // File access: replace lists if non-empty
        if !other.sandbox.files.read_only.is_empty() {
            self.sandbox.files.read_only = other.sandbox.files.read_only;
        }
        if !other.sandbox.files.read_write.is_empty() {
            self.sandbox.files.read_write = other.sandbox.files.read_write;
        }
        if !other.sandbox.files.no_access.is_empty() {
            self.sandbox.files.no_access = other.sandbox.files.no_access;
        }

        // Resources: override if set
        if other.sandbox.resources.max_memory.is_some() {
            self.sandbox.resources.max_memory = other.sandbox.resources.max_memory;
        }
        if other.sandbox.resources.max_cpus.is_some() {
            self.sandbox.resources.max_cpus = other.sandbox.resources.max_cpus;
        }

        // Budget: override if set
        if other.budget.max_cost_per_session.is_some() {
            self.budget.max_cost_per_session = other.budget.max_cost_per_session;
        }
        if other.budget.max_cost_per_call.is_some() {
            self.budget.max_cost_per_call = other.budget.max_cost_per_call;
        }
        self.budget.warn_threshold = other.budget.warn_threshold;

        // Behavior: override if set
        if other.behavior.initial_messages.is_some() {
            self.behavior.initial_messages = other.behavior.initial_messages;
        }
    }
}

/// LLM configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlmConfig {
    /// API endpoint (required, no default)
    #[serde(default)]
    pub endpoint: String,

    /// Model name (required)
    #[serde(default)]
    pub model: String,

    /// Environment variable containing API key
    pub api_key_env: Option<String>,

    /// Temperature for sampling
    pub temperature: Option<f32>,

    /// Maximum tokens in response
    pub max_tokens: Option<usize>,

    /// Custom system prompt suffix
    pub system_prompt_suffix: Option<String>,

    /// Model pricing (input_per_1k, output_per_1k)
    #[serde(default)]
    pub pricing: HashMap<String, TokenPricing>,
}

impl LlmConfig {
    /// Validate and convert to ValidatedLlmConfig for API usage.
    ///
    /// This method checks that all required fields are present and creates
    /// a ValidatedLlmConfig that can be used with LLM clients.
    pub fn validate(&self) -> Result<crate::llm::openai::ValidatedLlmConfig> {
        // Ensure endpoint is set
        if self.endpoint.is_empty() {
            anyhow::bail!("llm.endpoint is required");
        }

        // Ensure model is set
        if self.model.is_empty() {
            anyhow::bail!("llm.model is required");
        }

        // Get API key from environment variable
        let api_key_env = self.api_key_env.as_deref().unwrap_or("OPENAI_API_KEY");
        let api_key = std::env::var(api_key_env)
            .with_context(|| format!("Environment variable {} not set", api_key_env))?;

        // Get pricing for the model
        let pricing = self
            .pricing
            .get(&self.model)
            .copied()
            .unwrap_or_else(|| crate::llm::cost::get_pricing(&self.model));

        // Create validated config
        let mut validated = crate::llm::openai::ValidatedLlmConfig::new(
            self.endpoint.clone(),
            api_key,
            self.model.clone(),
            pricing,
        );

        // Set optional timeout (default is 60 seconds)
        if let Some(timeout) = self.max_tokens {
            validated = validated.with_timeout(timeout as u64);
        }

        Ok(validated)
    }
}

impl Default for LlmConfig {
    fn default() -> Self {
        let pricing = crate::llm::cost::default_pricing();

        Self {
            endpoint: String::new(),
            model: String::new(),
            api_key_env: Some("OPENAI_API_KEY".to_string()),
            temperature: Some(0.7),
            max_tokens: Some(4096),
            system_prompt_suffix: None,
            pricing,
        }
    }
}

/// Token pricing for a model (re-export from llm::cost)
pub use crate::llm::cost::TokenPricing;

/// Sandbox configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SandboxConfig {
    /// Shell prefix for wrapping interactive processes (e.g., "nix develop --command")
    /// This is passed to orchestrator via SHELL_PREFIX environment variable.
    /// Interactive environments (python, etc.) will spawn their processes using this prefix.
    /// Bash environment ignores this - agent controls bash shell directly.
    pub shell_prefix: Option<String>,

    /// Disable network access (default: false, network enabled)
    #[serde(default)]
    pub disable_network: bool,

    /// Path to custom sandbox script (optional, overrides default)
    pub sandbox_path: Option<PathBuf>,

    /// File access configuration (advisory in V1)
    #[serde(default)]
    pub files: FileAccessConfig,

    /// Resource limits (V1: not implemented, use systemd-run manually)
    #[serde(default)]
    pub resources: ResourceConfig,
}

/// File access configuration (advisory in V1)
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileAccessConfig {
    /// Files that should not be modified (glob patterns)
    #[serde(default)]
    pub read_only: Vec<String>,

    /// Files that can be modified (glob patterns)
    #[serde(default)]
    pub read_write: Vec<String>,

    /// Files that should not be accessed (glob patterns)
    #[serde(default)]
    pub no_access: Vec<String>,
}

/// Resource limits for container
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ResourceConfig {
    /// Maximum memory (e.g., "4G", "512M")
    pub max_memory: Option<String>,

    /// Maximum CPUs (e.g., "2.0", "0.5")
    pub max_cpus: Option<String>,
}

/// Budget configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetConfig {
    /// Maximum cost per session (dollars)
    pub max_cost_per_session: Option<Decimal>,

    /// Maximum cost per LLM call (dollars)
    pub max_cost_per_call: Option<Decimal>,

    /// Warn when reaching this fraction of session budget
    #[serde(default = "default_warn_threshold")]
    pub warn_threshold: Decimal,
}

fn default_warn_threshold() -> Decimal {
    Decimal::new(80, 2) // 0.80
}

impl Default for BudgetConfig {
    fn default() -> Self {
        Self {
            max_cost_per_session: None,
            max_cost_per_call: None,
            warn_threshold: default_warn_threshold(),
        }
    }
}

/// Behavioral configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BehaviorConfig {
    /// Whether agent should explain its actions
    #[serde(default = "default_explain_actions")]
    pub explain_actions: bool,

    /// Whether to ask before destructive operations
    #[serde(default)]
    pub ask_before_destructive: bool,

    /// Path to markdown file containing initial messages (optional)
    /// If not specified, defaults to checking for .7aigent-init.md in project directory
    /// If file doesn't exist, agent starts without initial messages
    pub initial_messages: Option<PathBuf>,
}

fn default_explain_actions() -> bool {
    true
}

impl Default for BehaviorConfig {
    fn default() -> Self {
        Self {
            explain_actions: default_explain_actions(),
            ask_before_destructive: false,
            initial_messages: None,
        }
    }
}

/// Configuration loader
pub struct ConfigLoader;

impl ConfigLoader {
    /// Load configuration from global and project files
    pub fn load() -> Result<Config> {
        // 1. Start with defaults
        let mut config = Config::default();

        // 2. Load global config if it exists
        if let Some(global_path) = Self::global_config_path() {
            if global_path.exists() {
                let global =
                    Self::load_from_file(&global_path).context("Failed to load global config")?;
                config.merge(global);
            }
        }

        // 3. Load project config if it exists
        if let Some(project_path) = Self::project_config_path() {
            if project_path.exists() {
                let project =
                    Self::load_from_file(&project_path).context("Failed to load project config")?;
                config.merge(project);
            }
        }

        // 4. Validate final config
        config.validate()?;

        Ok(config)
    }

    /// Load config from a specific file
    fn load_from_file(path: &PathBuf) -> Result<Config> {
        let contents = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;

        let config: Config = toml::from_str(&contents)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;

        Ok(config)
    }

    /// Get global config path (~/.config/7aigent/config.toml)
    fn global_config_path() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("7aigent").join("config.toml"))
    }

    /// Get project config path (./.7aigent.toml)
    fn project_config_path() -> Option<PathBuf> {
        std::env::current_dir()
            .ok()
            .map(|d| d.join(".7aigent.toml"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_is_invalid() {
        // Default config should be invalid (no endpoint/model set)
        let config = Config::default();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_valid_config() {
        let mut config = Config::default();
        config.llm.endpoint = "https://api.openai.com/v1".to_string();
        config.llm.model = "gpt-4".to_string();

        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_config_merge() {
        let mut base = Config::default();
        base.llm.endpoint = "https://base.example.com".to_string();
        base.llm.model = "base-model".to_string();
        base.sandbox.files.read_only = vec!["base/**".to_string()];

        let mut override_config = Config::default();
        override_config.llm.endpoint = "https://override.example.com".to_string();
        // Don't set model - should keep base's model
        override_config.sandbox.files.read_only = vec!["override/**".to_string()];

        base.merge(override_config);

        // Endpoint should be overridden
        assert_eq!(base.llm.endpoint, "https://override.example.com");
        // Model should stay from base
        assert_eq!(base.llm.model, "base-model");
        // Files should be overridden
        assert_eq!(base.sandbox.files.read_only, vec!["override/**"]);
    }

    #[test]
    fn test_config_serialization() {
        let config = Config {
            llm: LlmConfig {
                endpoint: "https://api.openai.com/v1".to_string(),
                model: "gpt-4".to_string(),
                api_key_env: Some("OPENAI_API_KEY".to_string()),
                temperature: Some(0.7),
                max_tokens: Some(4096),
                system_prompt_suffix: None,
                pricing: HashMap::new(),
            },
            sandbox: SandboxConfig::default(),
            budget: BudgetConfig::default(),
            behavior: BehaviorConfig::default(),
        };

        // Test that it can be serialized and deserialized
        let toml_str = toml::to_string(&config).unwrap();
        let deserialized: Config = toml::from_str(&toml_str).unwrap();

        assert_eq!(config.llm.endpoint, deserialized.llm.endpoint);
        assert_eq!(config.llm.model, deserialized.llm.model);
    }

    #[test]
    fn test_budget_validation() {
        let mut config = Config::default();
        config.llm.endpoint = "https://api.openai.com/v1".to_string();
        config.llm.model = "gpt-4".to_string();

        // Negative budget should fail
        config.budget.max_cost_per_session = Some(Decimal::new(-100, 2));
        assert!(config.validate().is_err());

        // Positive budget should work
        config.budget.max_cost_per_session = Some(Decimal::new(1000, 2));
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_warn_threshold_validation() {
        let mut config = Config::default();
        config.llm.endpoint = "https://api.openai.com/v1".to_string();
        config.llm.model = "gpt-4".to_string();

        // Threshold > 1 should fail
        config.budget.warn_threshold = Decimal::new(150, 2); // 1.5
        assert!(config.validate().is_err());

        // Threshold <= 0 should fail
        config.budget.warn_threshold = Decimal::ZERO;
        assert!(config.validate().is_err());

        // Valid threshold should work
        config.budget.warn_threshold = Decimal::new(80, 2); // 0.8
        assert!(config.validate().is_ok());
    }
}

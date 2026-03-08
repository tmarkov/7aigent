//! Template rendering for agent messages.
//!
//! This module provides markdown template rendering with {{key}} replacement syntax.
//! Templates are loaded from embedded defaults or project overrides.

use regex::Regex;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Template context holding key-value pairs for replacement
pub struct TemplateContext {
    values: HashMap<String, String>,
}

impl TemplateContext {
    /// Create a new empty context
    pub fn new() -> Self {
        Self {
            values: HashMap::new(),
        }
    }

    /// Insert a key-value pair
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.values.insert(key.into(), value.into());
    }

    /// Get a value by key
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(|s| s.as_str())
    }

    /// Check if a key exists
    pub fn contains_key(&self, key: &str) -> bool {
        self.values.contains_key(key)
    }

    /// Get all keys
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.values.keys()
    }
}

impl Default for TemplateContext {
    fn default() -> Self {
        Self::new()
    }
}

/// Template renderer with cascade loading support
pub struct TemplateRenderer {
    embedded: HashMap<String, &'static str>,
    project_dir: PathBuf,
}

impl TemplateRenderer {
    /// Create a new renderer with embedded templates and project directory
    pub fn new(project_dir: impl AsRef<Path>) -> Self {
        let mut embedded = HashMap::new();

        // Load embedded templates
        embedded.insert(
            "system.md".to_string(),
            include_str!("../templates/prompts/system.md"),
        );
        embedded.insert(
            "task.md".to_string(),
            include_str!("../templates/prompts/task.md"),
        );
        embedded.insert(
            "command_output.md".to_string(),
            include_str!("../templates/prompts/command_output.md"),
        );
        embedded.insert(
            "screen.md".to_string(),
            include_str!("../templates/prompts/screen.md"),
        );

        Self {
            embedded,
            project_dir: project_dir.as_ref().to_path_buf(),
        }
    }

    /// Load a template with cascade: project override OR embedded
    pub fn load_template(&self, name: &str) -> Result<String, TemplateError> {
        // Try project override first
        let override_path = self.project_dir.join(".7aigent/prompts").join(name);

        if override_path.exists() {
            std::fs::read_to_string(&override_path).map_err(|e| TemplateError::ReadError {
                path: override_path,
                source: e,
            })
        } else {
            // Fall back to embedded
            self.embedded
                .get(name)
                .map(|s| s.to_string())
                .ok_or_else(|| TemplateError::NotFound {
                    name: name.to_string(),
                })
        }
    }

    /// Render a template with the given context
    pub fn render(
        &self,
        template_name: &str,
        context: &TemplateContext,
    ) -> Result<String, TemplateError> {
        let template = self.load_template(template_name)?;

        // Extract all {{key}} patterns from template
        let key_pattern = Regex::new(r"\{\{(\w+)\}\}").unwrap();
        let mut required_keys: Vec<String> = Vec::new();

        for cap in key_pattern.captures_iter(&template) {
            let key = cap[1].to_string();
            if !required_keys.contains(&key) {
                required_keys.push(key);
            }
        }

        // Check for missing required keys (keys used in template but not provided)
        for key in &required_keys {
            if !context.contains_key(key) {
                return Err(TemplateError::MissingKey {
                    key: key.clone(),
                    template: template_name.to_string(),
                });
            }
        }

        // Note: We don't check for unused keys in context - custom templates
        // may omit keys that are provided, and that's fine.

        // Perform replacement
        let mut result = template;
        for key in required_keys {
            let value = context.get(&key).unwrap(); // Safe: we checked above
            let pattern = format!("{{{{{}}}}}", key);
            result = result.replace(&pattern, value);
        }

        Ok(result)
    }
}

/// Template errors
#[derive(Debug, thiserror::Error)]
pub enum TemplateError {
    #[error("Template not found: {name}")]
    NotFound { name: String },

    #[error("Failed to read template override: {path}")]
    ReadError {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Missing required key in template context: {key} (template: {template})")]
    MissingKey { key: String, template: String },
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_context_basic_operations() {
        let mut ctx = TemplateContext::new();

        ctx.insert("name", "Alice");
        ctx.insert("age", "30");

        assert_eq!(ctx.get("name"), Some("Alice"));
        assert_eq!(ctx.get("age"), Some("30"));
        assert_eq!(ctx.get("missing"), None);

        assert!(ctx.contains_key("name"));
        assert!(!ctx.contains_key("missing"));
    }

    #[test]
    fn test_basic_replacement() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let mut ctx = TemplateContext::new();
        ctx.insert("task", "Fix the bug");

        let result = renderer.render("task.md", &ctx).unwrap();
        assert_eq!(result.trim(), "Fix the bug");
    }

    #[test]
    fn test_multiple_occurrences_same_key() {
        let tmp = TempDir::new().unwrap();

        // Create a template with duplicate keys
        let template_dir = tmp.path().join(".7aigent/prompts");
        fs::create_dir_all(&template_dir).unwrap();
        fs::write(
            template_dir.join("test.md"),
            "Hello {{name}}, welcome {{name}}!",
        )
        .unwrap();

        let renderer = TemplateRenderer::new(tmp.path());
        let mut ctx = TemplateContext::new();
        ctx.insert("name", "Bob");

        let result = renderer.render("test.md", &ctx).unwrap();
        assert_eq!(result, "Hello Bob, welcome Bob!");
    }

    #[test]
    fn test_missing_required_key_error() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let ctx = TemplateContext::new(); // Empty context

        let err = renderer.render("task.md", &ctx).unwrap_err();
        match err {
            TemplateError::MissingKey { key, .. } => {
                assert_eq!(key, "task");
            }
            _ => panic!("Expected MissingKey error"),
        }
    }

    #[test]
    fn test_unused_keys_allowed() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let mut ctx = TemplateContext::new();
        ctx.insert("task", "Do something");
        ctx.insert("extra", "Not needed"); // Extra keys are allowed

        // Should succeed - unused keys in context are fine
        let result = renderer.render("task.md", &ctx).unwrap();
        assert_eq!(result.trim(), "Do something");
    }

    #[test]
    fn test_empty_value_handling() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let mut ctx = TemplateContext::new();
        ctx.insert("task", ""); // Empty value

        let result = renderer.render("task.md", &ctx).unwrap();
        assert_eq!(result.trim(), "");
    }

    #[test]
    fn test_whitespace_preservation() {
        let tmp = TempDir::new().unwrap();

        let template_dir = tmp.path().join(".7aigent/prompts");
        fs::create_dir_all(&template_dir).unwrap();
        fs::write(template_dir.join("test.md"), "  {{content}}  \n").unwrap();

        let renderer = TemplateRenderer::new(tmp.path());
        let mut ctx = TemplateContext::new();
        ctx.insert("content", "test");

        let result = renderer.render("test.md", &ctx).unwrap();
        assert_eq!(result, "  test  \n");
    }

    #[test]
    fn test_project_override_cascade() {
        let tmp = TempDir::new().unwrap();

        // Create override
        let template_dir = tmp.path().join(".7aigent/prompts");
        fs::create_dir_all(&template_dir).unwrap();
        fs::write(template_dir.join("task.md"), "CUSTOM: {{task}}").unwrap();

        let renderer = TemplateRenderer::new(tmp.path());
        let mut ctx = TemplateContext::new();
        ctx.insert("task", "Test");

        let result = renderer.render("task.md", &ctx).unwrap();
        assert_eq!(result, "CUSTOM: Test");
    }

    #[test]
    fn test_embedded_fallback() {
        let tmp = TempDir::new().unwrap();
        // No override created, should use embedded

        let renderer = TemplateRenderer::new(tmp.path());
        let mut ctx = TemplateContext::new();
        ctx.insert("task", "Test");

        let result = renderer.render("task.md", &ctx).unwrap();
        // Should use embedded template
        assert_eq!(result.trim(), "Test");
    }

    #[test]
    fn test_nonexistent_template_error() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let ctx = TemplateContext::new();

        let err = renderer.render("nonexistent.md", &ctx).unwrap_err();
        match err {
            TemplateError::NotFound { name } => {
                assert_eq!(name, "nonexistent.md");
            }
            _ => panic!("Expected NotFound error"),
        }
    }

    #[test]
    fn test_multiple_keys_replacement() {
        let tmp = TempDir::new().unwrap();

        let template_dir = tmp.path().join(".7aigent/prompts");
        fs::create_dir_all(&template_dir).unwrap();
        fs::write(
            template_dir.join("test.md"),
            "Name: {{name}}, Age: {{age}}, City: {{city}}",
        )
        .unwrap();

        let renderer = TemplateRenderer::new(tmp.path());
        let mut ctx = TemplateContext::new();
        ctx.insert("name", "Alice");
        ctx.insert("age", "30");
        ctx.insert("city", "Paris");

        let result = renderer.render("test.md", &ctx).unwrap();
        assert_eq!(result, "Name: Alice, Age: 30, City: Paris");
    }

    #[test]
    fn test_special_characters_in_value() {
        let tmp = TempDir::new().unwrap();
        let renderer = TemplateRenderer::new(tmp.path());

        let mut ctx = TemplateContext::new();
        ctx.insert("task", "Fix <bug> & update {{version}}");

        let result = renderer.render("task.md", &ctx).unwrap();
        assert!(result.contains("Fix <bug> & update {{version}}"));
    }
}

# Customizing Agent Prompts

This guide shows how to customize the messages 7aigent sends to the LLM by overriding markdown templates.

## Overview

All agent messages are generated from markdown templates with `{{key}}` replacement syntax:

- **System prompt**: Agent capabilities and instructions
- **Task message**: Initial task description
- **Command output**: Execution results
- **Screen state**: Current environment state

You can override these templates in your project without modifying the agent code.

## Template System

**Default templates**: Embedded in the agent binary (`agent/templates/prompts/`)

**Override location**: `.7aigent/prompts/` in your project directory

**Cascade**: The agent checks for project overrides first, then falls back to embedded defaults.

**Syntax**: `{{key}}` placeholders are replaced with actual values.

**Validation**: The agent errors if required keys are missing from the template context. Extra keys provided in context but not used by the template are silently ignored.

## Available Templates

### system.md

**Purpose**: System prompt sent once at the start of each session.

**Keys**:
- `read_only_files`: List of read-only file patterns (empty if none)
- `no_access_files`: List of no-access file patterns (empty if none)
- `additional_guidelines`: Additional behavioral guidelines based on config

**Default template**: See `agent/templates/prompts/system.md`

**Example override**:

```markdown
You are 7aigent, a specialized AI assistant.

Available environments:
- bash: Shell commands
- python: Python REPL
- editor: File editing

{{read_only_files}}{{no_access_files}}

Guidelines:
- Think step by step
- Verify your work
- Explain trade-offs
{{additional_guidelines}}
```

Note: You can't add custom keys like `{{project_type}}` — only predefined keys are supported. Using an undefined key causes a `MissingKey` error at runtime.

### task.md

**Purpose**: Initial task description sent as the first user message.

**Keys**:
- `task`: The task string provided by the user

**Default template**: `{{task}}`

**Example override**:

```markdown
# Task

{{task}}

# Instructions

Please provide:
1. Analysis of requirements
2. Implementation plan
3. Test strategy
4. Final verification
```

### command_output.md

**Purpose**: Formatting for command execution results.

**Keys**:
- `environment`: Environment name (e.g., "bash", "python")
- `command`: The command that was executed
- `output`: The command's output
- `exit_code`: Exit code or "N/A"
- `processed`: "yes" or "no" indicating if output was processed

**Default template**: See `agent/templates/prompts/command_output.md`

**Example override**:

```markdown
**Executed in {{environment}}**:
```
{{command}}
```

**Result** (exit: {{exit_code}}):
```
{{output}}
```
```

### screen.md

**Purpose**: Current state of all environments.

**Keys**:
- `screen`: Formatted screen content with all environment sections

**Default template**:

```markdown
=== Current Screen State ===

{{screen}}
```

**Example override**:

```markdown
# Current State

{{screen}}

---
Remember: The screen updates after each command. Previous screen content is not visible.
```

## Common Customization Patterns

### Add Domain-Specific Instructions

Create `.7aigent/prompts/system.md`:

```markdown
You are 7aigent, an AI assistant specialized in Rust development.

Available environments:
- bash: Execute shell commands (cargo, rustc, etc.)
- python: Python REPL (for scripting)
- editor: View and edit Rust files

{{read_only_files}}{{no_access_files}}

Rust-Specific Guidelines:
- Always run `cargo check` after code changes
- Use `cargo clippy` for linting
- Write tests for new functionality
- Follow Rust naming conventions

General Guidelines:
- Work step by step
- Check your work
- When done, explain what you accomplished
{{additional_guidelines}}
```

### Structured Task Format

Create `.7aigent/prompts/task.md`:

```markdown
## User Request

{{task}}

## Expected Deliverables

- [ ] Working implementation
- [ ] Tests passing
- [ ] Documentation updated
- [ ] Code formatted and linted
```

### Detailed Command Output

Create `.7aigent/prompts/command_output.md`:

```markdown
---
Environment: {{environment}}
Command: {{command}}
Exit Code: {{exit_code}}
Processed: {{processed}}
---

{{output}}

---
```

### Concise Screen Format

Create `.7aigent/prompts/screen.md`:

```markdown
{{screen}}
```

This removes the header, making the screen output more concise.

## Testing Your Templates

1. Create `.7aigent/prompts/` in your project
2. Add your template override (e.g., `system.md`)
3. Run the agent: `7aigent "test task"`
4. Check the session logs to verify template rendering

**Debug template issues**:
- Missing keys: Agent will error with "Missing required key: <key>"
- Extra keys in context are silently ignored — you cannot cause an error by providing unused keys
- Read template errors: Check file permissions and path

## Limitations

**Cannot add custom keys**: Templates only support predefined keys. You cannot extend the template context with new keys like `{{project_type}}` or `{{custom_instruction}}`.

**Cannot change message structure**: Templates control formatting but not the overall message flow (system → task → commands → screen).

**No conditionals or loops**: Templates only support simple `{{key}}` replacement, not logic like `{{#if}}` or `{{#each}}`.

**For advanced customization**: If you need more control, modify the agent code directly or use the `system_prompt_suffix` config option for appending to the system prompt.

## Reference

**Template validation**: All templates are validated at runtime. If a template references a key not provided in context, the agent fails immediately with a `MissingKey` error.

**Character encoding**: Templates must be UTF-8 encoded markdown files.

**Whitespace**: Preserved exactly as written in templates.

**Escaping**: No need to escape `<`, `>`, `&` or other characters. Templates are rendered as-is.

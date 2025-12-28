# Instructions for LLM Agents

When working on this project, follow these guidelines:

## Project Philosophy

**This project is designed for LLM-driven development.** The entire codebase will be written by LLMs, with minimal human review. This shapes our core principles:

1. **Strong static analysis and type safety**: We rely on compilers and type checkers to catch errors, not human code review
2. **"If it compiles, it works"**: Use type systems to make invalid states unrepresentable
3. **Comprehensive tooling**: Formatters and linters enforce conventions automatically
4. **Explicit over implicit**: Code should be clear and obvious, not clever
5. **Test thoroughly**: Property-based testing ensures correctness across input space

See [docs/coding-style.md](docs/coding-style.md) for detailed conventions that support these principles.

## General Workflow

1. **Read before writing**: Before making decisions or changes, read relevant documentation in ./docs/
2. **Use TodoWrite proactively**: For multi-step tasks, create a todo list at the start to track progress
3. **Update documentation as you go**: Keep docs current when completing tasks
4. **Update checklists**: Mark completed tasks in ./docs/planning/ files

## Making Decisions

1. **Ask clarifying questions**: Don't assume implementation details - ask first
2. **Respect boundaries**: If told "we're not ready to decide that yet," stop and ask how to proceed
3. **Document only what's decided**: Avoid documenting speculative or unconfirmed design choices
4. **Sequential over parallel**: Break complex decisions into smaller, sequential discussions rather than asking many questions at once

## Architecture and Design

1. **Start high-level**: Discuss architecture before selecting technologies
2. **Question your assumptions**: Before documenting, verify your understanding matches the intent
3. **Examples clarify**: When designing contracts or interfaces, provide concrete examples
4. **Defer specifics**: Mark implementation details as "to be determined" if they depend on future design work
5. **Leverage the type system**: Design APIs that use types to prevent misuse (see coding-style.md)

## Documentation Standards

1. **Separation of concerns**: Keep different topics in separate files (overview, technology, coding-style)
2. **Link related docs**: Cross-reference between documents where helpful
3. **Planning structure**: Follow the format in ./docs/planning/README.md for task files
4. **Update the planning index**: When creating new tasks, add them to ./docs/planning/README.md in dependency order

## Code Quality (When Implementing)

1. **Follow coding-style.md**: Adhere strictly to conventions in ./docs/coding-style.md
2. **Type safety first**: Use the type system to prevent errors
   - Rust: Use newtypes, enums, and the type system to make invalid states impossible
   - Python: Use frozen dataclasses and semantic types instead of primitives
3. **No escape hatches**: Avoid `.unwrap()` in Rust, avoid `Any` in Python unless absolutely necessary
4. **Test public APIs**: Write property-based tests using hypothesis (Python) or proptest (Rust)
5. **Document as you code**: Write docstrings and doc comments for all public APIs
6. **Let tools enforce quality**: Run rustfmt/clippy (Rust) and black/ruff (Python) before considering work done

## When You're Stuck

1. **Review related documentation**: Check ./docs/ for context and architectural decisions
2. **Ask the user**: Don't guess - ask for clarification or present options with trade-offs
3. **Suggest options**: Present trade-offs rather than making unilateral decisions
4. **Mark as TBD**: If something needs future discussion, explicitly mark it as "to be determined"
5. **Reflect on the philosophy**: Remember this is LLM-driven development - prioritize compile-time safety

## Success Criteria

You're doing well if:
- Code compiles/type-checks on first try (or after minimal fixes)
- Tools (rustfmt, clippy, black, ruff) pass without manual intervention
- Tests are comprehensive and use property-based testing where applicable
- Documentation is clear and up-to-date
- You ask questions when assumptions are unclear
- You follow the type safety patterns in coding-style.md

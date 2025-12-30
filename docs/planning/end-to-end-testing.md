# Description

Implement comprehensive end-to-end testing of the complete system with real LLM integration and example tasks.

# Plan

- [ ] Create test tasks
  - [ ] Simple bash task: "List files and count lines in README"
  - [ ] Python task: "Calculate mean of numbers in data.csv"
  - [ ] Editor task: "View and edit function in source file"
  - [ ] Multi-environment task: "Compile C program, test, fix bug"

- [ ] Implement test harness
  - [ ] Run agent with test tasks
  - [ ] Capture conversation history
  - [ ] Verify task completion
  - [ ] Measure token usage
  - [ ] Measure time to completion

- [ ] Test with real LLM
  - [ ] Configure API keys
  - [ ] Test with Claude (primary)
  - [ ] Test error handling (rate limits, etc.)

- [ ] Test scenarios from design review
  - [ ] C + Python optimization workflow
  - [ ] Multi-file refactoring
  - [ ] Data analysis with plots
  - [ ] GDB debugging (with ad-hoc environment)

- [ ] Performance testing
  - [ ] Measure screen update performance
  - [ ] Measure file I/O performance
  - [ ] Test with large files (10,000+ lines)
  - [ ] Test with many views

- [ ] Stress testing
  - [ ] Long-running commands
  - [ ] Large output handling
  - [ ] Memory usage with large Python objects
  - [ ] Many iterations in conversation

- [ ] Document findings
  - [ ] Record successful workflows
  - [ ] Document failure modes
  - [ ] Identify areas for improvement
  - [ ] Create examples for documentation

# Dependencies

- Requires: Complete system (agent + orchestrator + container)
- Requires: All environments implemented

# Outcome

Validated system that successfully completes real tasks with LLM, with documented performance characteristics and known limitations.

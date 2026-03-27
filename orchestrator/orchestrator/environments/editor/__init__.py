"""Query-based editor environment package.

This package implements a procedural query-based view system for the editor environment.

Main class:
    EditorEnvironment: The main editor environment implementation

Modules:
    environment: Main EditorEnvironment class implementation
    parser: Query string parsing (view and read-only-peek commands, matchers, operations)
    executor: Query pipeline execution (ripgrep backend, operations)
    windows: Window/view management (merging, deduplication, formatting)
    summarizer: AI summary generation via auxiliary LLM
    indentation: Indentation analysis for while-indent operation
"""

# Export main class
from orchestrator.environments.editor.environment import EditorEnvironment

# Export submodules for internal use
from orchestrator.environments.editor.executor import QueryExecutor
from orchestrator.environments.editor.indentation import IndentationAnalyzer
from orchestrator.environments.editor.parser import QueryParser
from orchestrator.environments.editor.summarizer import Summarizer
from orchestrator.environments.editor.windows import WindowManager

__all__ = [
    "EditorEnvironment",
    "QueryParser",
    "QueryExecutor",
    "WindowManager",
    "Summarizer",
    "IndentationAnalyzer",
]

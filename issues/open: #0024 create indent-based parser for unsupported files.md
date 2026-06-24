# Create indent-based parser for unsupported files

Files without a supported parser should still get a useful CodeTree structure.
Use indentation as the primary signal and keep the fallback non-semantic.

- Create fallback `block` nodes for indentation-derived groups.
- Create fallback `chunk` leaves for text not covered by child blocks.
- Expand tabs to a fixed width before measuring indentation.
- Ignore blank lines when detecting indentation changes.
- Keep blank lines in the emitted source spans.
- A nonblank line starts a candidate block when the next nonblank line is more indented.
- A candidate block ends before the first later nonblank line whose indentation is less than or equal to the candidate start indentation.
- Accept only candidates that cover a useful multi-line span.
- Allow a whole-file block child when the whole file is one useful structural group.
- Do not allow a child block to have the same span as its fallback block parent.
- Use gap filling so every parent span is fully covered by children.
- The leaf chunks under each subtree should collectively cover every line in that subtree.
- Split uncovered text into chunks by blank-line separated nonblank runs.
- Do not emit chunks that contain only blank lines.
- Attach blank-only runs to adjacent chunks when possible.
- If no adjacent chunk exists, attach blank-only runs to an adjacent block.
- Treat lines starting with `}`, `)`, `]`, or `</` as local closing lines.
- A local closing line directly after a block body can count toward accepting and closing that block.
- A connector line such as `} else {` belongs to the block it starts, not the preceding block.
- Adjacent blocks connected by such connector lines should be grouped under one non-semantic parent block.
- Keep the fallback parser conservative: it should not rely on delimiter balance across the file.
- Fallback nodes should not claim semantic kinds such as function, class, loop, or comment.
- Fallback files should not produce parser-derived summaries, signatures, or symbols.

## Examples

### Brace-style control flow

Source:

```c
1  int main() {
2      if (1 == 2) {
3          cout << "buggy compiler" << endl;
4      } else {
5          cout << "all good" << endl;
6      }
7
8      return 0;
9  }
```

Expected fallback tree:

```text
file 1-9
└── block 1-9
    ├── chunk 1-1
    ├── block 2-6
    │   ├── block 2-3
    │   │   └── chunk 2-3
    │   └── block 4-6
    │       └── chunk 4-6
    └── chunk 7-9
```

Notes:

- The `if` and `else` bodies are indentation candidates.
- Line 4 belongs to the `else` block because it starts that block.
- The adjacent `if` and `else` blocks are grouped under a non-semantic parent block.
- The final closing line and trailing return area are covered by gap chunks rather than semantic nodes.

### Short brace block

Source:

```c
1  if (enabled) {
2      run();
3  }
```

Expected fallback tree:

```text
file 1-3
└── block 1-3
    └── chunk 1-3
```

Notes:

- The indentation candidate is initially lines 1-2.
- The directly following local closing line makes the block a useful multi-line span.
- The fallback parser should keep the entire small block together.

### Blank before closing delimiter

Source:

```c
1  if (enabled) {
2      run();
3
4  }
```

Expected fallback tree:

```text
file 1-4
├── chunk 1-3
└── chunk 4-4
```

Notes:

- The blank line prevents the closing delimiter from being treated as directly attached to the block body.
- The fallback remains conservative and uses normal gap/chunk handling.

### Indentation-only structure

Source:

```text
1  pipeline:
2      fetch:
3          retries: 3
4          timeout: 10
5      build:
6          command: make all
7
8  notifications:
9      email: team@example.com
```

Expected fallback tree:

```text
file 1-9
├── block 1-7
│   ├── chunk 1-1
│   ├── block 2-4
│   │   └── chunk 2-4
│   └── block 5-7
│       └── chunk 5-7
└── block 8-9
    └── chunk 8-9
```

Notes:

- Section-like lines start blocks because their following nonblank lines are more indented.
- Blank lines stay in emitted spans and are absorbed into adjacent children.

### HTML/XML-like structure

Source:

```html
1  <section>
2    <h1>Title</h1>
3    <div>
4      <p>Hello</p>
5    </div>
6  </section>
```

Expected fallback tree:

```text
file 1-6
└── block 1-6
    ├── chunk 1-2
    ├── block 3-5
    │   └── chunk 3-5
    └── chunk 6-6
```

Notes:

- The nested `<div>` area is found by indentation.
- The `</div>` line is a local closing line and stays with the nested block.
- The fallback parser does not need to understand tag names.

### Function-like block with comment header

Source:

```text
1  # Printing helpers
2
3  pretty_print(format, x):
4      print("=========================")
5      if format == "04d":
6          print(x)
7      else:
8          print("unsupported")
```

Expected fallback tree:

```text
file 1-8
├── chunk 1-2
└── block 3-8
    ├── chunk 3-4
    ├── block 5-6
    │   └── chunk 5-6
    └── block 7-8
        └── chunk 7-8
```

Notes:

- The comment header remains a chunk; fallback nodes do not claim `comment` or `function` kinds.
- The function-like and branch-like structure is represented only as generic blocks.

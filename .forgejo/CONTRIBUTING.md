# Contributing to ZIX

Thank you for considering contributing to ZIX.
This document outlines the workflow, coding standards, and expectations for contributors.

## Table of Contents

- [Quick Start](#quick-start)
- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Coding Guidelines](#coding-guidelines)
- [Testing](#testing)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)
- [Questions](#questions)

## Quick Start

1. Fork the repository (main or mirror).
2. Clone your fork.
3. Run `zig build test-all && zig build test-runner-all` to verify the build.
4. Find an issue or propose a change.
5. Submit a pull request to main.

## How to Contribute

### Reporting Issues

- Check existing issues to avoid duplicates.
- Use the issue template when available.
- Include clear steps to reproduce.
- Describe expected vs actual behavior.
- Mention your operating system and Zig version.

### Proposing Changes

- Open an issue first for significant changes.
- Discuss the approach before writing code.
- For bug fixes, include a test that reproduces the issue.

### Languages Documentations

- Documentaion for another languages beside English and Bahasa are very welcome.

### Areas Needing Help

The project seeks maintainers and contributors for these platforms:

| Platform | Status |
| :- | :- |
| x86_64-windows | Looking for contributor and maintainer |
| aarch64-macos | Looking for contributor and maintainer |
| x86_64-freebsd | Looking for contributor and maintainer |
| x86_64-netbsd | Looking for contributor and maintainer |
| x86_64-openbsd | Looking for contributor and maintainer |

## Development Setup

### Requirements

- Git.
- Zig 0.16.x or later.

### Build

```bash
zig build test-all && zig build test-runner-all
```

## Coding Guidelines

These guidelines follow the project's philosophy: explicit over implicit, modular and maintainable, performance-first architecture.

Read more: https://codeberg.org/prothegee/zix/src/branch/main/docs/coding-guideline-en.md

### General Principles

- Single file, single responsibility.
- Always use and push Zig and its standard library.
- Avoid abstraction on specific engines or specific intents.
- What can be control/adjust to the caller/user, serve it to them when possible.
- Linux x86_64/aarch64 raw-syscall fast path is guarded, changes there can harm the implementation.

Read more: https://codeberg.org/prothegee/zix/src/branch/main/docs/systems-thinking-en.md

### Style Rules (Strict)

These rules are enforced across all code, comments, and documentation.

#### Table Formatting

Use `| :- |` for table headers, not `|---|`:

```markdown
| Header 1 | Header 2 |
| :- | :- |
| Value 1  | Value 2  |
```

#### Punctuation and Symbols

- Never use em-dash `—`. Use `:` to define after a subject, `()` for sub-explanations, `,` or `.` otherwise. Reserve `-` only for compound words (trade-off), not as a separator.
- Use only EN-US keyboard symbols:
  - `<=` not `≤`
  - `>=` not `≥`
  - `!=` not `≠`
  - `*` or `x` not `×`
  - `/` not `÷`
  - `->` not `→`
  - `~` not `≈`
  - `"` not `″`
  - `'` not `’`
  - `...` not `…`

#### Comment and Documentation Rules

- Comments:
    - `//!` Declare what is the specific file purpose.
    - `///` If variable, function, struct, enum, etc. is not obvious, explain (even for the params function).
    - `//` Use it as flow explanation, for test comment description, or to explain what it mean if code readability wasn't obvious.
- Single `-` is allowed in parameter doc comments as a definer (example: `/// param - type`).
- A single `-` is also allowed as an extendable definer (`X - Y`) when scoped after a `:` subject or inside `()`. Example: `Support: en - English, id - Bahasa` or `(io - std.Io, required, must outlive the server)`. This binds a label to its expansion and is list-able. It is distinct from the banned prose separator (a lone `-` hinging two clauses in open prose). Allowed only inside the `:` clause or the `()` group, never as a free-floating sentence break.

#### Diagrams

Use Mermaid for diagrams, not text-based diagrams.
If unsure ask. You may allowed to use text-based explanation when opening an issue.

### Commit Messages

- Run `zig fmt .` (Zig 0.16.x only. Do not use above thosee for now).
- Write clear, concise commit messages.
- Reference issue numbers when applicable.

## Testing

- Cover uncovered tests where possible.
- Run the full test suite before submitting a pull request.

```bash
zig build test-all && zig build test-runner-all 
```

- For specific test suites, refer to the test directory structure.

## Documentation

- Update documentation for any changed functionality.
- Use clear, simple language that a junior contributor can understand.
- For technical terms and established jargon (shared-nothing, slab, level-triggered, busy-poll, handoff), keep the English version.
- When translating to Indonesian, if the Indonesian phrasing does not reflect the original English naming or technical term, keep the English version.

### Documentation Structure

- High-level design documents are in `docs/hld-*.md`.
- Low-level design documents are in `docs/lld-*.md`.
- Use the table format for documentation references.

### Documentation Example

```markdown
| Document | Description |
| :- | :- |
| [`docs/hld-http-en.md`](docs/hld-http-en.md) | HTTP: goals, runtime model, API, router, WebSocket, SSE, memory model |
```

## Pull Request Process

1. Fork the repository and create a feature branch.
2. Make your changes with clear commit messages.
3. Run tests and ensure they pass.
4. Update documentation as needed.
5. Submit a pull request against the main branch.
6. Reference any related issues.

### Pull Request Checklist

- [ ] Code follows the coding guidelines.
- [ ] Tests pass locally.
- [ ] Documentation is updated.
- [ ] Commit messages are clear.
- [ ] No merge conflicts.

### Review Process

- Pull requests are reviewed by maintainers.
- Significant changes may require a proof of concept (RnD/PoC).
- Always fix from our side first rather than waiting for Zig features.

## Questions

- Open an issue for questions.
- Discuss in the project's issue tracker.
- Reach out to maintainers.

## AI Policies

- __*You can use it as your own tool.*__
- __*Issue & Pull Request must made on your behalf.*__

---

Thank you for contributing to ZIX.
Every contribution helps build a better network backend library.

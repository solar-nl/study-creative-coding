# Insights: Patterns for Your Rust Framework

This directory contains extracted patterns and recommendations from studying creative coding frameworks.

## Purpose

As you study each framework, document actionable insights here. These will inform the design of your Rust creative coding framework targeting desktop, mobile, and web.

## Documents

- **[API Recommendations](./api-recommendations.md)** — Best practices for user-facing APIs
- **[Architecture Decisions](./architecture-decisions.md)** — ADRs for your framework
- **[Rust-Specific Patterns](./rust-specific.md)** — Rust idioms that map to patterns found

## Extraction Process

When studying a framework:

1. Identify patterns that work well
2. Identify anti-patterns to avoid
3. Consider how it maps to Rust
4. Document in the appropriate file

## Key Questions to Answer

### API Design
- What makes an API "feel right" for creative coding?
- How much typing should users do for common operations?
- How to balance simplicity with power?

### Architecture
- How to structure for cross-platform (desktop, mobile, web)?
- How to separate core from optional features?
- How to support extensions/plugins?

### Rust-Specific
- How to leverage Rust's type system?
- How to make ownership ergonomic for creative coding?
- How to handle async (loading, events)?

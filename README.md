lua65 - An open source lua compiler
===================================

| Company | System                      |
|---------|-----------------------------|
|Nintendo |Nintendo Entertainment System|

## Hardened Type System & Explicit Annotations
• No Dynamic Types: Standard Lua uses run-time typing with heavy type-tagged wrappers, which is too expensive for 2KB of RAM. Instead, this compiler offloads all type-checking to compile-time.

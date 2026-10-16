# Feature review references

## Compare against
- Python: httpx, selectolax/bs4, rich, typer, pathlib, shutil.
- Node: zx, execa, got, cheerio, puppeteer, ink.
- Go/Rust CLI staples (cobra, clap, ripgrep-style globbing, indicatif).

## Module candidates to judge (do not assume them)
config/env (.env, TOML/YAML) · sqlite or kv store · cache · logging · scheduling · text tables/templating · clipboard/notifications · process supervision · websocket/SSE · mail · diff/patch · date/duration parsing.

For each: use case, a rough 3-line API, cost (deps, startup ms, lines), verdict. Re-judge earlier verdicts only with new evidence; the latest ones are in docs/PROPOSAL.md when it exists, else in the git log of its last round.

## Evidence that counts
- A call site in projects/ (medialoader, keybox) or the README tour.
- A "today vs proposed" snippet of 5–15 lines that you ran.
- Not counted: "other libraries have it", or a hypothetical user.

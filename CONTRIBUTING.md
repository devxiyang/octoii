# Contributing

Thanks for wanting to help. This repository takes contributions in a set order, so a maintainer can give each the time
it needs.

## Issues

- **New contributors' issues close on their own.** Maintainers read the closed ones daily and reopen those worth
  working on. A maintainer who replies `octoii:allow-issues` keeps your later issues open; `octoii:allow-prs` keeps your
  later issues and pull requests open.
- **What gets reopened:** one problem per issue, in your own words, short enough to read on one screen. A bug says what
  happened, the smallest steps that make it happen, and what you expected; a proposal says what to change and why.
  Search the open and closed issues first.
- **Security problems** are not issues: report them privately to the maintainers through GitHub's security advisories.

## Pull requests

- **Propose first.** Open a Contribution Proposal issue; a pull request from a contributor not approved with
  `octoii:allow-prs` closes on its own.
- **Checks pass.** `bun install`, then `bun run check`: formatting, lint, unused code, types, and the tests on Bun and
  on Node.
- **Keep it to one change**, written like the code around it, within the rules of [AGENTS.md](AGENTS.md): clear names,
  small functions, the simplest design that works, and nothing built before it is needed.
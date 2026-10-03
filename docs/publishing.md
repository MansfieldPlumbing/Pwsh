# Documentation and publishing

Status: protocol, 2026-10-03. First version; tighten it when it fails.

The repository is public on GitHub, so nothing in it is private. The two homes
differ in role and audience, not in secrecy, and the same rules on sensitive
content apply to both.

## Two homes

| | GitHub (`MansfieldPlumbing/Pwsh`) | learn.mansfieldplumbing.dev |
| --- | --- | --- |
| Role | Source of truth and engineering record | Curated reference for readers |
| Audience | Contributors and agents working on the code | People learning what Pwsh is and how it works |
| Holds | `AGENTS.md` (contract), `ROADMAP.md` (status), design documents, work orders, receipts, tools and tests | Concepts, how-to, reference and results articles derived from the repository |
| Voice | May carry work-order and status language, open questions, gate names | Reference voice; the same facts, organized for reading |
| Changes | Edited directly | Never edited first: fix the repository, then republish |

## What goes where

| Content | GitHub | Site |
| --- | --- | --- |
| Agent contract (`AGENTS.md`) | Yes | No; linked when an article cites it |
| Roadmap and implementation plan | Yes | Yes, as status pages |
| Design documents (`docs/*.md` concepts) | Yes | Yes, as concept articles |
| Work orders (`docs/work-*.md`) | Yes | Selected ones, marked Planned |
| Receipts | Summary document with hashes and checks | Results page derived from it |
| Raw evidence (logcat, screenshots, `receipt.json`) | No: stays in the ignored `build/` folder | No |
| Tools, tests, scripts | Yes | Described and linked, not copied |

## Never published, in either home

- Device identifiers (serial numbers, hardware and network identifiers, the platform device ID, account names) and the
  owner's personal device by name or model; a personal device is "an arm64
  physical device".
- Personal information: home directory paths, personal email, family, travel,
  location.
- Secrets: keys, tokens, passwords, signing material. The signing key stays in
  per-user storage; only its public certificate is in an APK.
- Detail of an unpatched vulnerability.
- Internals of private repositories beyond provenance (repository, commit,
  path).
- Raw device logs (they contain other apps' data) and screenshots showing
  anything beyond the app under test.

## Publishing steps

1. **Push first.** The site is generated only from a pushed commit of this
   repository, never from a working tree. The site never runs ahead of GitHub.
2. **Import at that commit.** The site repository's import tool takes the full
   commit SHA, reads the documents at that commit, converts them (front
   matter, site link targets, page titles as link text) and records the SHA in
   each article's front matter.
3. **Check.** Build with the site's committed template; every internal link and
   anchor resolves; the sensitive-content scan finds nothing.
4. **Deploy and record.** Deploy, then commit the site repository with the
   Pwsh SHA in the message.

Site-only material is limited to presentation: front matter, the table of
contents, link mapping and titles. A fact that appears on the site exists in
the repository at the recorded commit.

## Builds

An APK carries no personal data: script assets, the manifest and the emitted
assemblies are scanned for home paths, personal names beyond the published
author, emails and device identifiers before a build is shared. The APK's
signing certificate subject is reviewed once per signing identity.

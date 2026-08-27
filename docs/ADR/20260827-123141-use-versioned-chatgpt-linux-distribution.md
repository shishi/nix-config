# Use a Versioned ChatGPT Linux Distribution

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-08-27 |
| **Decision-makers** | shishi |
| **Consulted** | N/A |
| **Informed** | N/A |

## Context and Problem Statement

The previous Nix wrapper combined a fixed content hash with OpenAI's mutable
`/latest/` ChatGPT Desktop URL. When OpenAI published a new package, an existing
lock resolved the new bytes with the old hash, so unrelated flake updates could
no longer be built and validated.

## Decision Drivers

* A committed flake lock must continue to resolve the same upstream artifact.
* OpenAI package provenance and integrity should be checked before packaging.
* ChatGPT Desktop must run on NixOS without maintaining a local package fork.
* Community-specific behavior should remain disabled unless explicitly needed.

## Considered Options

1. Use `ilysenko/codex-desktop-linux` with its versioned official package pins.
2. Keep `poeck/chatgpt-desktop-app-nix-flake` and wait for each `/latest/` hash update.
3. Maintain a local derivation for the official Linux package.

## Decision Outcome

**Chosen option**: "Use `ilysenko/codex-desktop-linux`", because it resolves a
versioned package path from signed OpenAI APT metadata and preserves old locks
when OpenAI publishes a new version. Its Home Manager module also owns the
NixOS-specific runtime integration.

### Consequences

**Positive:**

* OpenAI releases no longer invalidate an existing package URL and hash pair.
* Package discovery verifies signed APT metadata and the selected package hash.
* NixOS-specific ELF and sandbox adaptations are maintained upstream.

**Negative:**

* The application depends on a larger third-party distribution and its release process.
* The distribution applies a Nix-specific application patch and uses a custom launcher.
* Updates require reviewing a broader upstream diff than the previous minimal wrapper.

**Neutral:**

* The command and desktop entry change from `chatgpt` and `chatgpt.desktop` to
  `codex-desktop` and `codex-desktop.desktop`.

### Confirmation

The `chatgpt-desktop-contract` flake check verifies that the package uses a
versioned repository URL, optional Linux features remain empty, community usage
reporting is disabled, the package's `--diagnose` command succeeds, and the KDE taskbar
uses the new desktop entry. A successful Jupiter system build and switch confirm
the complete integration.

## Pros and Cons of the Options

### Use `ilysenko/codex-desktop-linux`

* Good, because versioned package URLs preserve lock reproducibility.
* Good, because signed repository metadata and package hashes are verified.
* Good, because the project tests NixOS-specific runtime behavior.
* Bad, because the wrapper and optional feature framework increase the trusted code surface.

### Keep `poeck/chatgpt-desktop-app-nix-flake`

* Good, because its Nix packaging code is small and easy to review.
* Bad, because its mutable `/latest/` URL makes old fixed-output derivations fail after an upstream release.
* Bad, because all validated flake updates can be blocked while waiting for a matching wrapper update.

### Maintain a local derivation

* Good, because package policy and update timing would be fully controlled here.
* Bad, because this repository would own package discovery, provenance checks, ELF adaptation, and ongoing compatibility work.

## More Information

* [OpenAI ChatGPT Desktop for Linux](https://learn.chatgpt.com/docs/linux/linux-app)
* [codex-desktop-linux Nix documentation](https://github.com/ilysenko/codex-desktop-linux/blob/main/docs/nix.md)

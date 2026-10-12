# Release transport permission admission — 2026-10-12

The temporary transport run 38271469927 downloaded artifact 11757241914 with the expected digest, then received HTTP 403 at POST /releases. Its target d64c2a4623b042178960a27bcd409f5ed8a06ed1 changes workflow files relative to the default branch.

GitHub's official release endpoint documentation explicitly requires Workflows: write for a target commit adding or modifying .github/workflows files relative to the default branch. Built-in GITHUB_TOKEN cannot receive that permission:
https://docs.github.com/en/rest/releases/releases?apiVersion=latest#create-a-release

This is a release-token authorization requirement. Changing contents: write alone, retrying unchanged requests, or moving the tag to main does not fix the exact candidate's authorization contract.

## Implemented repair

- Before artifact download or release mutation, GET-only inspection resolves the default branch to an immutable snapshot and compares complete recursive trees with the exact candidate target.
- Truncated/malformed trees, mutable target refs, and mismatched commit resolution stop admission.
- Workflow additions, modifications, removals or mode changes require a configured transport credential. Default GITHUB_TOKEN stops with BLOCKED_WORKFLOWS_PERMISSION and exit 78.
- A configured credential is not a proof of permission: READY_PERMISSION_NOT_VERIFIED explicitly records token_permissions_verified=false. A subsequent 403 is still a real access blocker.
- The transport workflow remains manual, requires an absolute authorized deadline, retains six-minute job timeout, start reserve, exact archive hash and cleanup. It pins the release target to source 69982736eb073a8df53fbdbe4dc02509fc760807; it does not retarget a tag to avoid permission checks.
- No release creation or GPU test is part of the read-only diagnostic workflow.

## Configuration required for actual transfer

Repository secret PEPEW_RELEASE_TRANSPORT_TOKEN must contain an owner-approved GitHub App installation credential or fine-grained credential limited to iPepew/PepePow_Miner, with Contents: write and Workflows: write. The code does not create credentials, expand account permissions, or print token values. The existing artifact downloader continues using the built-in token with Actions: read.

The secret's presence and actual permissions have not been confirmed. Until configuration is provided and the exact transfer succeeds, GPU correctness, speed and release promotion of candidate 69982736 remain unverified. Production/default/stable/live are unchanged.

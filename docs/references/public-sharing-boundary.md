# Public Sharing Boundary

This template is meant to stay public-safe.

## Safe to publish

- bootstrap scripts
- monitoring scripts
- generalized runbooks
- example config files with placeholders
- generic anchor instructions

## Keep private

- live host inventory
- provider account details
- firewall IDs
- SSH private keys
- mnemonic words
- backup paths that reveal where secrets are stored
- per-tenant operational notes

## Recommended pattern

Keep:

- a small public operator-template repo
- a separate private ops repo for live fleet state

Do not try to make one repo serve both purposes.

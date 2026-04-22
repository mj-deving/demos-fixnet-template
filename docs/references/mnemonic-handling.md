# Mnemonic Handling

## Rules

- one mnemonic per node
- never commit mnemonics to git
- do not paste mnemonics into chat logs if you can avoid it
- keep file permissions strict: directory `700`, file `600`

## Recommended paths

On a host:

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
```

Store a mnemonic as:

```bash
~/.secrets/demos-mnemonic
```

Then:

```bash
chmod 600 ~/.secrets/demos-mnemonic
```

## Existing mnemonic workflow

If you already have an existing node identity:

1. place the mnemonic in a private file on the target host
2. pass that file to the node with `-i /path/to/file`
3. clear any stale first-boot database if the host previously generated a different identity

## Fresh mnemonic workflow

If you do not have an existing mnemonic:

1. let the first boot generate `.demos_identity`
2. move it to a private path under `~/.secrets`
3. back it up off-host

Do not run multiple hosts with the same mnemonic.

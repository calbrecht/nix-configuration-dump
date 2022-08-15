### Example usage
```
nix eval -L --impure --verbose --expr 'import ./nix-configuration-dump/dump-configuration.nix' clean --json | jq -c '.[]'
```

Known Bugs and workarounds:
If nix tries to evaluate random files in /tmp directory simple clear the whole /tmp directory ¯\_( ͡° ͜ʖ ͡°)_/¯

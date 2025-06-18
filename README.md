# jackpkgs

Jack's nix packages.

## Packages

This repository includes the following packages:

- `csharpier` - C# code formatter
- `docfx` - Documentation generation tool for .NET
- `epub2tts` - EPUB to Text-to-Speech converter
- `lean` - Lean theorem prover
- `nbstripout` - Strip output from Jupyter notebooks
- `roon-server` - Roon audio server

## Using the Overlay

### Method 1: Using the Default Overlay

You can use the default overlay that includes all packages:

```nix
let
  jackpkgs = fetchGit {
    url = "https://github.com/jmmaloney4/jackpkgs.git";
    # Optional: specify a specific commit
    # rev = "commit-hash-here";
  };
  
  pkgs = import <nixpkgs> {
    overlays = [ (import "${jackpkgs}/overlays/default.nix").default ];
  };
in
{
  # Now you can use the packages
  environment.systemPackages = with pkgs; [
    csharpier
    docfx
    epub2tts
    lean
    nbstripout
    roon-server
  ];
}
```

### Method 2: Using the Main Overlay

Alternatively, you can use the main overlay that includes all packages plus lib, modules, and overlays:

```nix
let
  jackpkgs = fetchGit {
    url = "https://github.com/jmmaloney4/jackpkgs.git";
  };
  
  pkgs = import <nixpkgs> {
    overlays = [ (import "${jackpkgs}/overlay.nix") ];
  };
in
{
  # Use the packages
  environment.systemPackages = with pkgs; [
    csharpier
    docfx
    # ... other packages
  ];
}
```

### Method 3: Direct Package Import

You can also import packages directly without using overlays:

```nix
let
  jackpkgs = fetchGit {
    url = "https://github.com/jmmaloney4/jackpkgs.git";
  };
  
  pkgs = import <nixpkgs> {};
  
  jackPackages = import jackpkgs { inherit pkgs; };
in
{
  environment.systemPackages = [
    jackPackages.csharpier
    jackPackages.docfx
    # ... other packages
  ];
}
```

### Method 4: Flake Usage

If you're using Nix flakes, you can add this repository as an input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
  };

  outputs = { self, nixpkgs, jackpkgs }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ jackpkgs.overlays.default ];
          
          environment.systemPackages = with pkgs; [
            csharpier
            docfx
            epub2tts
            lean
            nbstripout
            roon-server
          ];
        })
      ];
    };
  };
}
```

## Development

To build a specific package:

```bash
nix-build -A packagename
```

To build all packages:

```bash
nix-build
```


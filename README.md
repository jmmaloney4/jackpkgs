# jackpkgs
[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fjmmaloney4%2Fjackpkgs)](https://garnix.io/repo/jmmaloney4/jackpkgs)

Jack's `nix` packages.

## Packages

This repository includes the following packages:

- `csharpier` - C# code formatter
- `docfx` - Documentation generation tool for .NET
- `epub2tts` - EPUB to Text-to-Speech converter
- `lean` - Lean theorem prover
- `nbstripout` - Strip output from Jupyter notebooks
- `roon-server` - Roon audio server (x86_64-linux only)
- `tod` - Command line interface for Todoist

## Home Manager Modules

This repository also provides Home Manager modules:

- `tod` - Home Manager module for configuring the Tod CLI

### Using Home Manager Modules

#### Standalone Home Manager

If you're using Home Manager standalone:

```nix
let
  jackpkgs = fetchGit {
    url = "https://github.com/jmmaloney4/jackpkgs.git";
    # Optional: specify a specific commit
    # rev = "commit-hash-here";
  };
  
  jackPackages = import jackpkgs { pkgs = import <nixpkgs> {}; };
in
{
  imports = [ jackPackages.homeManagerModules.programs.tod ];
  
  programs.tod = {
    enable = true;
    settings = {
      # Your tod configuration here
    };
    apiTokenFile = "/path/to/your/todoist-token";
  };
}
```

#### Home Manager as NixOS Module

If you're using Home Manager as a NixOS module:

```nix
let
  jackpkgs = fetchGit {
    url = "https://github.com/jmmaloney4/jackpkgs.git";
  };
  
  jackPackages = import jackpkgs { pkgs = import <nixpkgs> {}; };
in
{
  home-manager.users.myuser = {
    imports = [ jackPackages.homeManagerModules.programs.tod ];
    
    programs.tod = {
      enable = true;
      settings = {
        # Your tod configuration here
      };
      apiTokenFile = "/path/to/your/todoist-token";
    };
  };
}
```

#### Flake Usage with Home Manager

If you're using Nix flakes with Home Manager:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
  };

  outputs = { self, nixpkgs, home-manager, jackpkgs }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        jackpkgs.homeManagerModules.programs.tod
        {
          programs.tod = {
            enable = true;
            settings = {
              # Your tod configuration here
            };
            apiTokenFile = "/path/to/your/todoist-token";
          };
        }
      ];
    };
  };
}
```

#### Flake Usage with NixOS + Home Manager

For NixOS configurations using Home Manager:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jackpkgs.url = "github:jmmaloney4/jackpkgs";
  };

  outputs = { self, nixpkgs, home-manager, jackpkgs }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        home-manager.nixosModules.home-manager
        {
          home-manager.users.myuser = {
            imports = [ jackpkgs.homeManagerModules.programs.tod ];
            
            programs.tod = {
              enable = true;
              settings = {
                # Your tod configuration here
              };
              apiTokenFile = "/path/to/your/todoist-token";
            };
          };
        }
      ];
    };
  };
}
```

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
    tod
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
    tod
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
    jackPackages.tod
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
            tod
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


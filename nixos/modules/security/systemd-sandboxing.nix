{
  pkgs,
  config,
  lib,
  ...
}: let
  inherit (lib) types;

  mkDefaults = builtins.mapAttrs (name: value: lib.mkDefault value);

  # The NixOS module system does not handle removing elements
  # from list settings. We want this module to have the semantics:
  # opt-in to all sandboxing by default and opt out for things
  # that you do need.
  handleBlocks = {
    blocked,
    allowed,
  }:
    builtins.map (val: "~${val}") (lib.subtractLists allowed blocked);
in {
  options.systemd.services = lib.mkOption {
    type = types.attrsOf (types.submodule ({
      name,
      config,
      ...
    }: let
      sandboxSettings = rec {
        none = {};
        hardened = {
          AmbientCapabilities = "";
          CapabilityBoundingSet = "";
          DynamicUser = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          MountAPIVFS = true;
          PrivateDevices = true;
          PrivateMounts = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "full";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          UMask = "066";

          RestrictAddressFamilies = handleBlocks {
            blocked = [
              "AF_PACKET"
              "AF_NETLINK"
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            allowed = config.allowAddressFamilies;
          };

          SystemCallFilter = handleBlocks {
            blocked = [
              "@clock"
              "@cpu-emulation"
              "@debug"
              "@module"
              "@mount"
              "@obsolete"
              "@privileged"
              "@raw-io"
              "@reboot"
              "@resources"
              "@swap"
            ];
            allowed = config.allowSystemCalls;
          };
        };

        isolated =
          hardened // {
            # Create an isolated root directory for the service. Later
            # on, we also make the unit closure available inside of the
            # chroot. The user needs to opt into this.
            RootDirectory = "%t/${name}";
            RuntimeDirectory = name;
          };
      };
    in {
      options.sandboxProfile = lib.mkOption {
        type = types.enum ["none" "hardened" "isolated"];
        default = "none";
      };

      options.allowSystemCalls = lib.mkOption {
        type = types.listOf types.str;
        default = [];
      };

      options.allowAddressFamilies = lib.mkOption {
        type = types.listOf types.str;
        default = [
          "AF_INET"
          "AF_INET6"
        ];
      };

      options.extraReadOnlyPaths = lib.mkOption {
        type = types.listOf types.str;
        default = [
          "/bin/sh"
          "/etc/ssl/certs/ca-bundle.crt"
        ];
      };

      options.extraReadWritePaths = lib.mkOption {
        type = types.listOf types.str;
        default = [];
      };

      config.serviceConfig = mkDefaults sandboxSettings.${config.sandboxProfile};
    }));
  };

  # Generate a bunch of derivations containing files like this:
  #
  #   # lib/systemd/system/<name>.service.d/sandbox.conf
  #   [Service]
  #   BindOnlyReadPaths=/nix/store/...
  #   BindReadWritePaths=/nix/store/...
  #   ...
  #
  # We add this to `systemd.packages`, which is a list of packages
  # to look for for extra systemd settings / directives.
  config.systemd.packages = let
    getUnitClosure = name: cfg: let
      svc = cfg.serviceConfig;
    in
      # Implementation trick: write out a textfile with the contents
      # of all of the `Exec*` options. Nix gives us information about
      # the closure of this file later.
      #
      # We also include `/bin/sh`, as a lot of programming languages
      # use this to spawn external programs.
      pkgs.writeText "${name}-closure" [
        (svc.ExecReload or "")
        (svc.ExecStart or "")
        (svc.ExecStartPost or "")
        (svc.ExecStartPre or "")
        (svc.ExecStop or "")
        (svc.ExecStopPost or "")
      ];

    createSandboxPackage = name: cfg:
      builtins.derivation {
        system = config.nixpkgs.system;
        name = "${name}-sandbox-conf";

        # Tell Nix to pass all information about this derivation
        # using the `.attrs.json` file instead of as env vars.
        __structuredAttrs = true;

        unitName = name;
        extraReadOnlyPaths = cfg.extraReadOnlyPaths;
        extraReadWritePaths = cfg.extraReadWritePaths;

        # Ask Nix to include dependency info in `.attrs.json`.
        # This information has the following shape / schema:
        #
        #   "unitClosure": [
        #     {"path": "/nix/store/...", ...},
        #     {"path": "/nix/store/...", ...},
        #     ...
        #   ]
        #
        # This will contain the Nix closure of the text file
        # we generated above.
        exportReferencesGraph.unitClosure = getUnitClosure name cfg;

        binSh = config.environment.binsh;

        builder = "${pkgs.python311}/bin/python";
        args = [
          (builtins.toFile "build.py" ''
            import json
            import sys
            from pathlib import Path

            # Load the structured information from the file that
            # Nix has generated for us due to `__structuredAttrs`.
            attrs = json.loads(Path(".attrs.json").read_text())

            # The path in the Nix store we can write our build
            # output to. This is the same thing as `$out` in a
            # `stdenv.mkDerivation`.
            out = Path(attrs["outputs"]["out"])

            closure_path = Path(attrs["exportReferencesGraph"]["unitClosure"])
            bin_sh = Path(attrs["binSh"])
            unit_name = attrs["unitName"]

            # This is the path we'll write our final config to.
            conf = out / f"lib/systemd/system/{unit_name}.service.d/sandbox.conf"
            conf.parent.mkdir(parents=True)

            with conf.open(mode="w") as c:
                c.write("[Service]\n")

                for dep in attrs["unitClosure"]:
                    store_path = Path(dep["path"])

                    # We do not need the textfile in the runtime
                    # information of the final systemd service.
                    if store_path == closure_path:
                        continue

                    c.write(f"BindReadOnlyPaths={store_path}\n")

                for path in attrs["extraReadOnlyPaths"]:
                    c.write(f"BindReadOnlyPaths={path}\n")

                for path in attrs["extraReadWritePaths"]:
                    c.write(f"BindReadWritePaths={path}\n")
          '')
        ];
      };

    unitsToSandbox =
      lib.filterAttrs
      (name: cfg: cfg.sandboxProfile == "isolated")
      config.systemd.services;
  in
    lib.mapAttrsToList createSandboxPackage unitsToSandbox;
}

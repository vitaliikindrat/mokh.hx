{
  description = "mokh.hx: Claude Code IDE integration for Helix (Steel)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0";
    in
    {
      packages = forAll (
        pkgs:
        let
          fs = pkgs.lib.fileset;
        in
        rec {
          # The Rust sidecar: lock file, WebSocket, MCP. Also ships the
          # `claude-sim` example as a self-test client.
          mokh-bridge = pkgs.rustPlatform.buildRustPackage {
            pname = "mokh-bridge";
            inherit version;
            src = fs.toSource {
              root = ./bridge;
              fileset = fs.unions [
                ./bridge/Cargo.toml
                ./bridge/Cargo.lock
                ./bridge/src
                ./bridge/examples
                ./bridge/tests
              ];
            };
            cargoLock.lockFile = ./bridge/Cargo.lock;
            cargoBuildFlags = [
              "--bins"
              "--examples"
            ];
            postInstall = ''
              install -Dm755 target/*/release/examples/claude-sim $out/bin/claude-sim 2>/dev/null \
                || install -Dm755 target/release/examples/claude-sim $out/bin/claude-sim
            '';
            meta = {
              description = "Claude Code IDE bridge for Helix (mokh.hx)";
              homepage = "https://github.com/vitaliikindrat/mokh.hx";
              license = pkgs.lib.licenses.mit;
              mainProgram = "mokh-bridge";
            };
          };

          # The Steel cog, in the layout helix-plugins-nix and forge expect:
          # a directory named after the cog holding cog.scm and the sources.
          # `passthru.cogName` lets helix-plugins-nix's module install it.
          mokh = pkgs.stdenvNoCC.mkDerivation {
            pname = "helix-plugin-mokh";
            inherit version;
            src = fs.toSource {
              root = ./.;
              fileset = fs.unions [
                ./cog.scm
                ./mokh.scm
                ./util.scm
              ];
            };
            dontBuild = true;
            installPhase = ''
              mkdir -p $out
              install -m644 *.scm $out/
            '';
            passthru = {
              cogName = "mokh";
              bridge = mokh-bridge;
            };
            meta = {
              description = "Claude Code IDE integration for Helix (Steel plugin)";
              homepage = "https://github.com/vitaliikindrat/mokh.hx";
              license = pkgs.lib.licenses.mit;
            };
          };

          default = mokh-bridge;
        }
      );

      checks = forAll (pkgs: {
        bridge = self.packages.${pkgs.system}.mokh-bridge;
        steel-tests =
          pkgs.runCommand "mokh-steel-tests" { nativeBuildInputs = [ pkgs.steel ]; }
            ''
              cp -r ${./.}/. .
              chmod -R u+w .
              sh tests/run-all.sh
              touch $out
            '';
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            rustfmt
            clippy
            steel
          ];
        };
      });
    };
}

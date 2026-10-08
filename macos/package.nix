{
  lib,
  stdenv,
  swift,
  darwin,
  version ? "0.0.0-dev",
}:

# Tetherbug.app built from source with nixpkgs' Swift and Apple SDK; `tetherbug` on PATH is its CLI.
stdenv.mkDerivation {
  pname = "tetherbug";
  inherit version;
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Sources
      ./build.sh
    ];
  };

  nativeBuildInputs = [
    swift
    darwin.sigtool
  ];

  buildPhase = ''
    runHook preBuild
    SWIFTC=swiftc NO_SIGN=1 bash build.sh "$out/Applications" ${version} ${stdenv.hostPlatform.darwinArch}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    ln -s "$out/Applications/Tetherbug.app/Contents/MacOS/Tetherbug" "$out/bin/tetherbug"
    runHook postInstall
  '';

  # After fixup, which would otherwise replace this signature with a linker-style one.
  postFixup = ''
    codesign --force --sign - --identifier ie.xav.tetherbug "$out/Applications/Tetherbug.app/Contents/MacOS/Tetherbug"
  '';

  meta = {
    description = "Turn your Android phone's hotspot on from your Mac, iPhone Instant Hotspot style";
    homepage = "https://github.com/xav-ie/Tetherbug";
    platforms = lib.platforms.darwin;
    license = lib.licenses.mit;
    mainProgram = "tetherbug";
  };
}

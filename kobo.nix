# The plugin as a directory you can drop straight onto a Kobo.
#
#   nix build .#kobo
#   scp -r result/ereolen.koplugin kobo:/mnt/onboard/.adds/koreader/plugins/
#
# Same Lua as the ordinary package, but with the ARM build of the wrapper
# instead of the host one. The .so goes in lib/ because that is the only place
# KOReader looks: pluginloader.lua puts "<plugin_root>/lib/?.so" on
# package.cpath and nothing else.
{ lib, stdenvNoCC, ereolenWrapperKobo }:

stdenvNoCC.mkDerivation {
  pname = "ereolen-koplugin-kobo";
  version = "0.1.0";

  src = ./.;

  dontConfigure = true;
  dontBuild = true;

  # The payload is an ARM shared object. The usual fixups are host tools and
  # would either fail on it or quietly rewrite something -- the x86_64 package
  # visibly "shrinks RPATHs" on its copy, which is not something to let near a
  # cross-built artefact.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/ereolen.koplugin/lib"
    cp ereolen.koplugin/*.lua "$out/ereolen.koplugin/"
    cp ${ereolenWrapperKobo}/lib/libereolenwrapper.so "$out/ereolen.koplugin/lib/"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    so="$out/ereolen.koplugin/lib/libereolenwrapper.so"
    test -f "$so"
    test -f "$out/ereolen.koplugin/main.lua"
    test -f "$out/ereolen.koplugin/_meta.lua"

    # Reading from a file rather than a pipe on purpose: the stdenv sets
    # `set -o pipefail`, so a `grep -q` that exits early would kill readelf
    # with SIGPIPE and fail the pipeline whatever it found.
    ${lib.getExe' ereolenWrapperKobo.koboToolchain "arm-kobo-linux-gnueabihf-readelf"} \
      -h "$so" > header.txt
    grep -q 'Machine:.*ARM' header.txt \
      || { echo "the bundled wrapper is not an ARM build"; exit 1; }

    echo "--- shipping:"
    ls "$out/ereolen.koplugin"
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "ereolen.koplugin bundled with the Kobo build of libereolenwrapper";
    homepage = "https://github.com/xdHampus/ereolen.koplugin";
    license = licenses.lgpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}

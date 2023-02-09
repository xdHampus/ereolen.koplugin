{ lib, stdenv, ereolenWrapperLua ? null}:

assert ereolenWrapperLua != null;

stdenv.mkDerivation rec {
  pname = "ereolen-koplugin";
  version = "0.1.0";

  src = ./.;

  buildInputs = [ ereolenWrapperLua ];

  installPhase = ''
  	mkdir -p ./ereolen.koplugin/lib
  	cp ${ereolenWrapperLua}/lib/libereolenwrapper.so ./ereolen.koplugin/lib/
  	mkdir -p $out/ereolen.koplugin
    mv ./ereolen.koplugin $out/
  '';

  
  meta = with lib; {
    homepage = "https://github.com/xdHampus/ereolen.koplugin";
    description = ''
      KOReader plugin for interacting with eReolen.dk
    '';
    licencse = licenses.lgpl3Plus;
    platforms = with platforms; linux ++ darwin;
    maintainers = [ maintainers.xdhampus ];
  };
}
